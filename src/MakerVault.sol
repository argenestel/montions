// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMontionsBook} from "./interfaces/IMontionsBook.sol";
import {IQuoter} from "./interfaces/IQuoter.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title MakerVault
/// @notice ERC4626-style market-making vault that posts a symmetric ladder on MontionsBook.
/// @dev Shares are 6-decimal ERC20 (`mmUSDC`). NAV is free Book cash + locked cash + idle USDC
///      + outcome inventory marked conservatively (SPEC 9 + amendment A8).
///
///      Ladder: 3 levels per side, 2-tick spacing, around `Quoter.fair`.
///      `timeDecayWidth = 4 * sqrt(10 minutes / timeToExpiry)` clamped to [2, 12].
///      `halfSpread = max(2, ceil(timeDecayWidth))` ticks.
///      Quoting stops (cancel, do not repost) when timeToExpiry < 10 minutes, fair is 0 /
///      unsupported, the series is not Open, quoting is paused, or the resolver is not the
///      owner-configured trusted resolver.
///
///      Caps (owner may only tighten within hard maxima):
///        - per-series worst-case exposure ≤ 10% NAV (default = hard max)
///        - global worst-case exposure (locked + unpaired inventory at 1 USDC) ≤ 30% NAV
///        - free Book cash ≥ 20% NAV after quoting, else cancel instead of post
///
///      HONESTY / RISKS:
///      - Adverse selection: anyone may take the resting ladder. The vault is last to know
///        when the fair value has moved; inventory will be on the wrong side of informed flow.
///      - NAV marks are conservative (min(fair, best-bid) for YES; symmetric for NO) and can
///        gap to 0 when there is no opposite quote, so share price is not a tradable bid.
///      - Withdrawals pay only free cash (after cancelling up to 64 tracked orders). Inventory
///        is not liquidated into USDC on withdraw; it must be quoted out or redeemed after
///        settlement.
///      - Close-NO bids are not used (the Book in this deployment may not support them). YES
///        inventory is exited via fromHeld asks; unpaired NO is held until merge is possible
///        or the series settles. The vault does not take liquidity to flatten NO.
contract MakerVault is ERC20, Ownable, ReentrancyGuard {
    uint256 internal constant UNIT = 1_000_000;
    uint256 internal constant TICK_UNIT = 10_000;
    uint256 internal constant TICKS = 100;
    uint256 internal constant MIN_QUOTE_LIFE = 10 minutes;
    uint256 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant VIRTUAL_SHARES = 10 ** DECIMALS_OFFSET;
    uint64 internal constant MAX_QTY = uint64((uint256(1) << 40) - 1);
    uint8 internal constant MAX_ORDERS_PER_SERIES = 8;
    uint8 internal constant MAX_CANCELS_PER_CALL = 64;
    uint8 internal constant LEVELS = 3;
    uint8 internal constant LEVEL_SPACING = 2;
    uint16 internal constant BPS_DENOM = 10_000;

    /// @notice Hard maximum per-series exposure (10%).
    uint16 public constant HARD_MAX_SERIES_EXPOSURE_BPS = 1_000;
    /// @notice Hard maximum global exposure (30%).
    uint16 public constant HARD_MAX_GLOBAL_EXPOSURE_BPS = 3_000;
    /// @notice Hard minimum free-cash buffer (20%).
    uint16 public constant HARD_MIN_FREE_CASH_BPS = 2_000;

    /// @notice Montions CLOB the vault quotes on.
    IMontionsBook public immutable book;
    /// @notice Fair-value oracle used to centre the ladder.
    IQuoter public immutable quoter;
    /// @notice Underlying collateral (Book USDC). ERC4626 `asset()`.
    address public immutable asset;

    /// @notice Optional keeper authorized to call `refresh`.
    address public keeper;
    /// @notice If non-zero, series whose resolver differs are ignored (A1).
    address public trustedResolver;
    /// @notice When true, `refresh` only cancels and never reposts.
    bool public quotingPaused;
    /// @notice When true, deposits and mints are blocked while withdrawals remain available.
    bool public depositsPaused;
    /// @notice Maximum NAV after a deposit or mint. Lowering below current NAV only blocks new deposits.
    uint256 public maxTotalAssets = type(uint256).max;

    /// @notice Per-series worst-case exposure cap in bps of NAV.
    uint16 public maxSeriesExposureBps = HARD_MAX_SERIES_EXPOSURE_BPS;
    /// @notice Global worst-case exposure cap in bps of NAV.
    uint16 public maxGlobalExposureBps = HARD_MAX_GLOBAL_EXPOSURE_BPS;
    /// @notice Minimum free Book cash in bps of NAV that must remain after quoting.
    uint16 public minFreeCashBps = HARD_MIN_FREE_CASH_BPS;

    struct SeriesOrders {
        uint64[8] ids;
        uint8 count;
    }

    mapping(bytes32 seriesId => SeriesOrders orders) internal _seriesOrders;
    bytes32[] internal _activeSeries;
    mapping(bytes32 seriesId => uint256 indexPlusOne) internal _activeIndex;

    error ZeroAddress();
    error ZeroAmount();
    error NotKeeper();
    error CapTooHigh();
    error CapTooLow();
    error InsufficientCash();
    error WithdrawMoreThanMax();
    error RedeemMoreThanMax();
    error DepositMoreThanMax();
    error MintMoreThanMax();
    error SeriesNotSettled();
    error VaultCapExceeded();
    error DepositsPaused();
    error TwoStepOwnershipRequired();
    error OwnershipRenunciationDisabled();

    /// @notice Emitted on ERC4626-style deposit or mint.
    event Deposit(address indexed by, address indexed owner, uint256 assets, uint256 shares);
    /// @notice Emitted on ERC4626-style withdraw or redeem.
    event Withdraw(address indexed by, address indexed to, address indexed owner, uint256 assets, uint256 shares);
    /// @notice Emitted when the keeper address changes.
    event KeeperSet(address indexed keeper);
    /// @notice Emitted when exposure / free-cash caps change.
    event CapsSet(uint16 seriesBps, uint16 globalBps, uint16 minFreeBps);
    /// @notice Emitted when the trusted resolver (A1) changes.
    event TrustedResolverSet(address indexed resolver);
    /// @notice Emitted when quoting is paused or resumed.
    event QuotingPausedSet(bool paused);
    /// @notice Emitted when deposits are paused or resumed.
    event DepositsPausedSet(bool paused);
    /// @notice Emitted when the total-assets cap changes.
    event MaxTotalAssetsSet(uint256 maxTotalAssets);
    /// @notice Emitted after a refresh attempt.
    event Refreshed(bytes32 indexed seriesId, bool quoted, uint8 posted);
    /// @notice Emitted when settled inventory is redeemed into Book cash.
    event SeriesRedeemed(bytes32 indexed seriesId, uint256 payout);

    /// @param book_ MontionsBook.
    /// @param quoter_ IQuoter (fair ticks).
    /// @param owner_ Administrator (caps, keeper, pause). Cannot withdraw depositor funds.
    constructor(address book_, address quoter_, address owner_) {
        if (book_ == address(0) || quoter_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        book = IMontionsBook(book_);
        quoter = IQuoter(quoter_);
        address col = IMontionsBook(book_).collateral();
        if (col == address(0)) revert ZeroAddress();
        asset = col;
        _initializeOwner(owner_);
        SafeTransferLib.safeApprove(col, book_, type(uint256).max);
    }

    /// @notice Disables Solady's direct one-step ownership transfer; use the handover flow.
    function transferOwnership(address) public payable override onlyOwner {
        revert TwoStepOwnershipRequired();
    }

    /// @notice Disables renunciation so administrative safety controls cannot be stranded.
    function renounceOwnership() public payable override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    function name() public pure override returns (string memory) {
        return "Montions Maker Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "mmUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function _constantNameHash() internal pure override returns (bytes32) {
        return keccak256("Montions Maker Vault");
    }

    // ───────────────────────── admin ─────────────────────────

    /// @notice Sets the keeper that may call `refresh`. Owner only. Zero disables the keeper.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Configures the resolver the vault will quote (A1). Zero disables the check.
    function setTrustedResolver(address resolver_) external onlyOwner {
        trustedResolver = resolver_;
        emit TrustedResolverSet(resolver_);
    }

    /// @notice Tightens quoting caps within hard maxima. Owner only.
    /// @param seriesBps Per-series exposure cap, ≤ 10%.
    /// @param globalBps Global exposure cap, ≤ 30%.
    /// @param minFreeBps Free-cash floor, ≥ 20% and ≤ 100%.
    function setCaps(uint16 seriesBps, uint16 globalBps, uint16 minFreeBps) external onlyOwner {
        if (seriesBps > HARD_MAX_SERIES_EXPOSURE_BPS) revert CapTooHigh();
        if (globalBps > HARD_MAX_GLOBAL_EXPOSURE_BPS) revert CapTooHigh();
        if (minFreeBps < HARD_MIN_FREE_CASH_BPS) revert CapTooLow();
        if (minFreeBps > BPS_DENOM) revert CapTooHigh();
        maxSeriesExposureBps = seriesBps;
        maxGlobalExposureBps = globalBps;
        minFreeCashBps = minFreeBps;
        emit CapsSet(seriesBps, globalBps, minFreeBps);
    }

    /// @notice Pauses or resumes quoting. Pause still allows refresh-to-cancel. Owner only.
    function setQuotingPaused(bool paused) external onlyOwner {
        quotingPaused = paused;
        emit QuotingPausedSet(paused);
    }

    /// @notice Pauses or resumes ERC4626 deposits and mints; withdrawals are never paused.
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    /// @notice Sets the maximum total NAV accepted by deposits and mints.
    /// @dev Lowering the cap below current NAV is allowed and only blocks new deposits.
    function setMaxTotalAssets(uint256 cap) external onlyOwner {
        maxTotalAssets = cap;
        emit MaxTotalAssetsSet(cap);
    }

    // ───────────────────────── ERC4626 surface ─────────────────────────

    /// @notice NAV in collateral units: idle USDC + Book free + Book locked + conservative inventory.
    function totalAssets() public view returns (uint256) {
        uint256 nav = SafeTransferLib.balanceOf(asset, address(this));
        nav += book.cash(address(this));
        nav += book.lockedCash(address(this));
        uint256 n = _activeSeries.length;
        for (uint256 i; i < n; ++i) {
            nav += _markSeries(_activeSeries[i]);
        }
        return nav;
    }

    /// @notice Assets → shares with virtual offset `decimalsOffset = 6` (inflation defence).
    function convertToShares(uint256 assets_) public view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(assets_, totalSupply() + VIRTUAL_SHARES, totalAssets() + 1);
    }

    /// @notice Shares → assets with the same virtual offset.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(shares, totalAssets() + 1, totalSupply() + VIRTUAL_SHARES);
    }

    /// @notice Preview of shares minted for `assets_` (rounds down).
    function previewDeposit(uint256 assets_) public view returns (uint256) {
        return convertToShares(assets_);
    }

    /// @notice Preview of assets required to mint `shares` (rounds up).
    function previewMint(uint256 shares) public view returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(shares, totalAssets() + 1, totalSupply() + VIRTUAL_SHARES);
    }

    /// @notice Preview of shares burned to withdraw `assets_` (rounds up).
    function previewWithdraw(uint256 assets_) public view returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(assets_, totalSupply() + VIRTUAL_SHARES, totalAssets() + 1);
    }

    /// @notice Preview of assets returned for `shares` (rounds down).
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice Maximum assets this receiver may deposit without exceeding the cap or pause.
    function maxDeposit(address) public view returns (uint256) {
        if (depositsPaused) return 0;
        uint256 nav = totalAssets();
        if (nav >= maxTotalAssets) return 0;
        return maxTotalAssets - nav;
    }

    /// @notice Maximum shares this receiver may mint without exceeding the cap or pause.
    function maxMint(address receiver) public view returns (uint256) {
        if (depositsPaused) return 0;
        if (maxTotalAssets == type(uint256).max) return type(uint256).max;
        return convertToShares(maxDeposit(receiver));
    }

    /// @notice Max assets `owner_` can withdraw: min of share value and currently liquid USDC
    ///         (idle + Book free + Book locked, which withdraw will try to cancel).
    function maxWithdraw(address owner_) public view returns (uint256) {
        uint256 byShares = convertToAssets(balanceOf(owner_));
        uint256 liquid = _liquidCash();
        return byShares < liquid ? byShares : liquid;
    }

    /// @notice Max shares `owner_` can redeem, limited by liquid cash.
    function maxRedeem(address owner_) public view returns (uint256) {
        uint256 bal = balanceOf(owner_);
        uint256 liquid = _liquidCash();
        uint256 byLiquid = convertToShares(liquid);
        return bal < byLiquid ? bal : byLiquid;
    }

    /// @notice Deposit `assets_` of collateral, minting shares to `receiver`.
    function deposit(uint256 assets_, address receiver) external nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets_ == 0) revert ZeroAmount();
        if (depositsPaused) revert DepositsPaused();
        if (assets_ > maxDeposit(receiver)) revert VaultCapExceeded();
        shares = previewDeposit(assets_);
        if (shares == 0) revert ZeroAmount();
        _deposit(msg.sender, receiver, assets_, shares);
    }

    /// @notice Mint exactly `shares` to `receiver` by depositing the required assets.
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets_) {
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        if (depositsPaused) revert DepositsPaused();
        if (shares > maxMint(receiver)) revert VaultCapExceeded();
        assets_ = previewMint(shares);
        if (assets_ == 0) revert ZeroAmount();
        _deposit(msg.sender, receiver, assets_, shares);
    }

    /// @notice Withdraw exactly `assets_` to `receiver`, burning shares from `owner_`.
    /// @dev Cancels up to 64 tracked orders to free cash. Reverts if still insufficient.
    function withdraw(uint256 assets_, address receiver, address owner_)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (receiver == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (assets_ == 0) revert ZeroAmount();
        if (assets_ > convertToAssets(balanceOf(owner_))) revert WithdrawMoreThanMax();
        shares = previewWithdraw(assets_);
        _withdraw(msg.sender, receiver, owner_, assets_, shares);
    }

    /// @notice Redeem exactly `shares` from `owner_`, sending assets to `receiver`.
    function redeem(uint256 shares, address receiver, address owner_) external nonReentrant returns (uint256 assets_) {
        if (receiver == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        if (shares > balanceOf(owner_)) revert RedeemMoreThanMax();
        assets_ = previewRedeem(shares);
        if (assets_ == 0) revert ZeroAmount();
        _withdraw(msg.sender, receiver, owner_, assets_, shares);
    }

    // ───────────────────────── quoting ─────────────────────────

    /// @notice Cancel the series ladder and, if allowed, post a fresh 3x2 ladder around fair.
    /// @dev Owner or keeper only (A8). Always cancels tracked orders first.
    function refresh(bytes32 seriesId) external nonReentrant {
        _onlyKeeper();
        _cancelSeriesOrders(seriesId, MAX_ORDERS_PER_SERIES);

        IMontionsBook.SeriesInfo memory info;
        try book.seriesInfo(seriesId) returns (IMontionsBook.SeriesInfo memory got) {
            info = got;
        } catch {
            _tryDeactivate(seriesId);
            emit Refreshed(seriesId, false, 0);
            return;
        }

        if (info.status == IMontionsBook.Status.Open) {
            _mergePaired(seriesId, info);
        }

        bool canQuote = !quotingPaused && info.status == IMontionsBook.Status.Open;
        if (canQuote && trustedResolver != address(0) && info.resolver != trustedResolver) {
            canQuote = false;
        }
        if (canQuote) {
            if (block.timestamp >= info.expiry) {
                canQuote = false;
            } else if (uint256(info.expiry) - block.timestamp < MIN_QUOTE_LIFE) {
                canQuote = false;
            }
        }

        uint8 fairTick;
        if (canQuote) {
            try quoter.fair(seriesId) returns (uint8 t, uint256, uint256, uint256) {
                fairTick = t;
            } catch {
                fairTick = 0;
            }
            if (fairTick == 0 || fairTick > 99) canQuote = false;
        }

        uint8 posted;
        if (canQuote) {
            posted = _postLadder(seriesId, info, fairTick);
        }
        _tryDeactivate(seriesId);
        emit Refreshed(seriesId, canQuote && posted > 0, posted);
    }

    /// @notice Claim settled / voided inventory into Book cash. Permissionless.
    function redeemSeries(bytes32 seriesId) external nonReentrant returns (uint256 payout) {
        _cancelSeriesOrders(seriesId, MAX_ORDERS_PER_SERIES);
        IMontionsBook.SeriesInfo memory info = book.seriesInfo(seriesId);
        if (info.status != IMontionsBook.Status.Resolved && info.status != IMontionsBook.Status.Void) {
            revert SeriesNotSettled();
        }
        uint256 y = book.balanceOf(address(this), info.yesId);
        uint256 n = book.balanceOf(address(this), info.noId);
        if (y != 0 || n != 0) {
            payout = book.redeem(seriesId, y, n);
        }
        _tryDeactivate(seriesId);
        emit SeriesRedeemed(seriesId, payout);
    }

    // ───────────────────────── views ─────────────────────────

    /// @notice Tracked order ids for a series (may include already-filled ids until the next refresh).
    function trackedOrders(bytes32 seriesId) external view returns (uint64[] memory ids) {
        SeriesOrders storage so = _seriesOrders[seriesId];
        ids = new uint64[](so.count);
        for (uint256 i; i < so.count; ++i) {
            ids[i] = so.ids[i];
        }
    }

    /// @notice Series the vault currently tracks (orders and/or inventory).
    function activeSeries() external view returns (bytes32[] memory) {
        return _activeSeries;
    }

    /// @notice Half-spread in ticks for a given time-to-expiry.
    /// @dev `timeDecayWidth = 4 * sqrt(600 / tte)` clamped to [2, 12];
    ///      `halfSpread = max(2, ceil(timeDecayWidth))`.
    function halfSpread(uint256 timeToExpiry) public pure returns (uint8) {
        if (timeToExpiry == 0) return 12;
        uint256 ratioWad = FixedPointMathLib.divWad(MIN_QUOTE_LIFE, timeToExpiry);
        uint256 w = FixedPointMathLib.sqrtWad(ratioWad); // sqrt(600/tte) * 1e18
        uint256 width = (4 * w + 1e18 - 1) / 1e18; // ceil(4 * sqrt(...))
        if (width < 2) width = 2;
        if (width > 12) width = 12;
        return uint8(width);
    }

    /// @notice Unique bid/ask ticks for a fair value and half-spread, clamped to 1..99.
    function ladderTicks(uint8 fairTick, uint8 hs) public pure returns (uint8[] memory bids, uint8[] memory asks) {
        uint8[3] memory rawBids;
        uint8[3] memory rawAsks;
        for (uint8 i; i < LEVELS; ++i) {
            rawBids[i] = _bidTick(fairTick, hs, i);
            rawAsks[i] = _askTick(fairTick, hs, i);
        }
        (bids, asks) = _collapse(rawBids, rawAsks);
    }

    // ───────────────────────── ERC1155 receiver ─────────────────────────

    /// @notice Accept Book outcome tokens. Fills themselves do not invoke this hook.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /// @notice Accept batched Book outcome tokens.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    /// @notice ERC165: ERC165 + ERC1155TokenReceiver.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x4e2312e0;
    }

    // ───────────────────────── internals: ERC4626 ─────────────────────────

    function _deposit(address by, address to, uint256 assets_, uint256 shares) internal {
        SafeTransferLib.safeTransferFrom(asset, by, address(this), assets_);
        if (totalAssets() > maxTotalAssets) revert VaultCapExceeded();
        _mint(to, shares);
        _depositToBook();
        emit Deposit(by, to, assets_, shares);
    }

    function _withdraw(address by, address to, address owner_, uint256 assets_, uint256 shares) internal {
        if (by != owner_) _spendAllowance(owner_, by, shares);
        _freeCash(assets_);
        _burn(owner_, shares);
        _sweepToVault(assets_);
        SafeTransferLib.safeTransfer(asset, to, assets_);
        emit Withdraw(by, to, owner_, assets_, shares);
    }

    function _depositToBook() internal {
        uint256 idle = SafeTransferLib.balanceOf(asset, address(this));
        if (idle != 0) book.deposit(idle);
    }

    function _sweepToVault(uint256 amount) internal {
        uint256 idle = SafeTransferLib.balanceOf(asset, address(this));
        if (idle >= amount) return;
        uint256 need = amount - idle;
        uint256 free = book.cash(address(this));
        if (free < need) revert InsufficientCash();
        book.withdraw(need);
    }

    function _liquidCash() internal view returns (uint256) {
        return
            SafeTransferLib.balanceOf(asset, address(this)) + book.cash(address(this)) + book.lockedCash(address(this));
    }

    function _freeCash(uint256 needed) internal {
        if (_idleAndFree() >= needed) return;
        uint256 remaining = MAX_CANCELS_PER_CALL;
        uint256 i = _activeSeries.length;
        while (i != 0 && remaining != 0) {
            unchecked {
                --i;
            }
            uint256 cancelled = _cancelSeriesOrders(_activeSeries[i], remaining);
            remaining -= cancelled;
            if (_idleAndFree() >= needed) return;
        }
        if (_idleAndFree() < needed) revert InsufficientCash();
    }

    function _idleAndFree() internal view returns (uint256) {
        return SafeTransferLib.balanceOf(asset, address(this)) + book.cash(address(this));
    }

    // ───────────────────────── internals: ladder ─────────────────────────

    function _postLadder(bytes32 seriesId, IMontionsBook.SeriesInfo memory info, uint8 fairTick)
        internal
        returns (uint8 posted)
    {
        (uint8[] memory bids, uint8[] memory asks) =
            ladderTicks(fairTick, halfSpread(uint256(info.expiry) - block.timestamp));
        if (bids.length == 0 && asks.length == 0) return 0;

        uint256 nav = totalAssets();
        if (nav == 0) return 0;

        (uint256 yesQty, uint256 noQty) = _balances(seriesId, info);
        uint256 unpaired = yesQty > noQty ? yesQty - noQty : noQty - yesQty;
        uint64 q = _sizeQty(nav, unpaired * UNIT, _tickWeightOf(bids, asks));

        posted = _placeBids(seriesId, bids, q);
        posted += _placeAsks(seriesId, asks, q, yesQty);

        if (posted != 0 || yesQty != 0 || noQty != 0) _ensureActive(seriesId);
    }

    function _tickWeightOf(uint8[] memory bids, uint8[] memory asks) internal pure returns (uint256 w) {
        for (uint256 i; i < bids.length; ++i) {
            w += bids[i];
        }
        for (uint256 i; i < asks.length; ++i) {
            w += (TICKS - asks[i]);
        }
    }

    function _sizeQty(uint256 nav, uint256 invExp, uint256 tickWeight) internal view returns (uint64 q) {
        uint256 budget = _quoteBudget(nav, invExp);
        if (tickWeight == 0 || budget == 0) return 0;
        uint256 raw = budget / (tickWeight * TICK_UNIT);
        if (raw > MAX_QTY) raw = MAX_QTY;
        q = uint64(raw);
    }

    function _quoteBudget(uint256 nav, uint256 invExp) internal view returns (uint256 budget) {
        uint256 seriesRoom = nav * maxSeriesExposureBps / BPS_DENOM;
        seriesRoom = seriesRoom > invExp ? seriesRoom - invExp : 0;
        uint256 globalNow = book.lockedCash(address(this)) + _worstCaseInventory();
        uint256 globalRoom = nav * maxGlobalExposureBps / BPS_DENOM;
        globalRoom = globalRoom > globalNow ? globalRoom - globalNow : 0;
        uint256 free = book.cash(address(this));
        uint256 minFree = nav * minFreeCashBps / BPS_DENOM;
        uint256 freeRoom = free > minFree ? free - minFree : 0;
        budget = seriesRoom;
        if (globalRoom < budget) budget = globalRoom;
        if (freeRoom < budget) budget = freeRoom;
    }

    function _placeBids(bytes32 seriesId, uint8[] memory bids, uint64 q) internal returns (uint8 posted) {
        if (q == 0) return 0;
        (uint8 bestBid_, uint64 bidQty_, uint8 bestAsk,) = book.bestBidAsk(seriesId);
        bestBid_;
        bidQty_;
        for (uint256 i; i < bids.length; ++i) {
            uint8 tick = bids[i];
            if (bestAsk != 0 && tick >= bestAsk) continue;
            posted += _place(seriesId, IMontionsBook.Side.Bid, tick, q, false);
        }
    }

    function _placeAsks(bytes32 seriesId, uint8[] memory asks, uint64 q, uint256 remainingYes)
        internal
        returns (uint8 posted)
    {
        (uint8 bestBid, uint64 bidQty_, uint8 bestAsk_, uint64 askQty_) = book.bestBidAsk(seriesId);
        bestAsk_;
        bidQty_;
        askQty_;
        for (uint256 i; i < asks.length; ++i) {
            uint8 tick = asks[i];
            if (bestBid != 0 && tick <= bestBid) continue;
            (uint64 qty, bool fromHeld) = _askQty(q, remainingYes);
            if (qty == 0) continue;
            uint8 placed = _place(seriesId, IMontionsBook.Side.Ask, tick, qty, fromHeld);
            if (placed != 0 && fromHeld) remainingYes -= qty;
            posted += placed;
        }
    }

    function _askQty(uint64 q, uint256 remainingYes) internal pure returns (uint64 qty, bool fromHeld) {
        if (remainingYes != 0) {
            uint256 take = remainingYes;
            if (q != 0 && q < take) take = q;
            if (take > MAX_QTY) take = MAX_QTY;
            return (uint64(take), true);
        }
        if (q == 0) return (0, false);
        return (q, false);
    }

    function _place(bytes32 seriesId, IMontionsBook.Side side, uint8 tick, uint64 qty, bool fromHeld)
        internal
        returns (uint8 posted)
    {
        if (qty == 0) return 0;
        SeriesOrders storage so = _seriesOrders[seriesId];
        if (so.count >= MAX_ORDERS_PER_SERIES) return 0;
        IMontionsBook.PlaceParams memory p = IMontionsBook.PlaceParams({
            seriesId: seriesId,
            side: side,
            tick: tick,
            qty: qty,
            fromHeld: fromHeld,
            tif: IMontionsBook.TIF.POST_ONLY,
            maxFills: 1
        });
        try book.placeOrder(p) returns (uint64 id, uint64, uint64 resting) {
            if (resting != 0) {
                so.ids[so.count] = id;
                unchecked {
                    ++so.count;
                }
                _ensureActive(seriesId);
                posted = 1;
            }
        } catch {}
    }

    function _bidTick(uint8 fairTick, uint8 hs, uint8 i) internal pure returns (uint8) {
        uint256 down = uint256(hs) + uint256(i) * LEVEL_SPACING;
        if (down >= fairTick) return 1;
        uint256 t = uint256(fairTick) - down;
        if (t < 1) return 1;
        if (t > 99) return 99;
        return uint8(t);
    }

    function _askTick(uint8 fairTick, uint8 hs, uint8 i) internal pure returns (uint8) {
        uint256 t = uint256(fairTick) + uint256(hs) + uint256(i) * LEVEL_SPACING;
        if (t < 1) return 1;
        if (t > 99) return 99;
        return uint8(t);
    }

    function _collapse(uint8[3] memory rawBids, uint8[3] memory rawAsks)
        internal
        pure
        returns (uint8[] memory bids, uint8[] memory asks)
    {
        uint8[3] memory uBids;
        uint8[3] memory uAsks;
        uint8 nb;
        uint8 na;
        uint8 last;
        for (uint256 i; i < LEVELS; ++i) {
            uint8 t = rawBids[i];
            if (i == 0 || t != last) {
                uBids[nb] = t;
                unchecked {
                    ++nb;
                }
                last = t;
            }
        }
        last = 0;
        for (uint256 i; i < LEVELS; ++i) {
            uint8 t = rawAsks[i];
            if (i == 0 || t != last) {
                uAsks[na] = t;
                unchecked {
                    ++na;
                }
                last = t;
            }
        }

        uint8 lowestAsk = 100;
        for (uint256 i; i < na; ++i) {
            if (uAsks[i] < lowestAsk) lowestAsk = uAsks[i];
        }
        uint8[3] memory fBids;
        uint8 fb;
        for (uint256 i; i < nb; ++i) {
            if (uBids[i] < lowestAsk) {
                fBids[fb] = uBids[i];
                unchecked {
                    ++fb;
                }
            }
        }
        uint8 highestBid;
        for (uint256 i; i < fb; ++i) {
            if (fBids[i] > highestBid) highestBid = fBids[i];
        }
        uint8[3] memory fAsks;
        uint8 fa;
        for (uint256 i; i < na; ++i) {
            if (uAsks[i] > highestBid) {
                fAsks[fa] = uAsks[i];
                unchecked {
                    ++fa;
                }
            }
        }

        bids = new uint8[](fb);
        asks = new uint8[](fa);
        for (uint256 i; i < fb; ++i) {
            bids[i] = fBids[i];
        }
        for (uint256 i; i < fa; ++i) {
            asks[i] = fAsks[i];
        }
    }

    // ───────────────────────── internals: orders / series ─────────────────────────

    function _cancelSeriesOrders(bytes32 seriesId, uint256 limit) internal returns (uint256 cancelled) {
        SeriesOrders storage so = _seriesOrders[seriesId];
        if (so.count == 0) return 0;

        uint64[] memory openIds = new uint64[](so.count);
        uint256 nOpen;
        for (uint256 i; i < so.count; ++i) {
            uint64 id = so.ids[i];
            if (id == 0) continue;
            if (book.orderInfo(id).open) {
                openIds[nOpen] = id;
                unchecked {
                    ++nOpen;
                }
            }
        }

        uint256 toCancel = nOpen;
        if (toCancel > limit) toCancel = limit;

        if (toCancel != 0) {
            uint64[] memory batch = new uint64[](toCancel);
            for (uint256 i; i < toCancel; ++i) {
                batch[i] = openIds[i];
            }
            book.cancelOrders(batch);
            cancelled = toCancel;
        }

        uint256 remaining = nOpen - toCancel;
        so.count = uint8(remaining);
        for (uint256 i; i < MAX_ORDERS_PER_SERIES; ++i) {
            so.ids[i] = i < remaining ? openIds[toCancel + i] : 0;
        }
    }

    function _mergePaired(bytes32 seriesId, IMontionsBook.SeriesInfo memory info) internal {
        uint256 y = book.balanceOf(address(this), info.yesId);
        uint256 n = book.balanceOf(address(this), info.noId);
        uint256 m = y < n ? y : n;
        if (m == 0) return;
        if (m > type(uint64).max) m = type(uint64).max;
        book.merge(seriesId, uint64(m));
    }

    function _ensureActive(bytes32 seriesId) internal {
        if (_activeIndex[seriesId] != 0) return;
        _activeSeries.push(seriesId);
        _activeIndex[seriesId] = _activeSeries.length;
    }

    function _tryDeactivate(bytes32 seriesId) internal {
        if (_seriesOrders[seriesId].count != 0) return;
        IMontionsBook.SeriesInfo memory info;
        try book.seriesInfo(seriesId) returns (IMontionsBook.SeriesInfo memory got) {
            info = got;
        } catch {
            _removeActive(seriesId);
            return;
        }
        if (book.balanceOf(address(this), info.yesId) != 0) return;
        if (book.balanceOf(address(this), info.noId) != 0) return;
        _removeActive(seriesId);
    }

    function _removeActive(bytes32 seriesId) internal {
        uint256 idx1 = _activeIndex[seriesId];
        if (idx1 == 0) return;
        uint256 idx = idx1 - 1;
        uint256 last = _activeSeries.length - 1;
        if (idx != last) {
            bytes32 moved = _activeSeries[last];
            _activeSeries[idx] = moved;
            _activeIndex[moved] = idx + 1;
        }
        _activeSeries.pop();
        _activeIndex[seriesId] = 0;
    }

    function _onlyKeeper() internal view {
        if (msg.sender != owner() && msg.sender != keeper) revert NotKeeper();
    }

    // ───────────────────────── internals: NAV / exposure ─────────────────────────

    function _balances(bytes32 seriesId, IMontionsBook.SeriesInfo memory info)
        internal
        view
        returns (uint256 y, uint256 n)
    {
        y = book.balanceOf(address(this), info.yesId);
        n = book.balanceOf(address(this), info.noId);
        SeriesOrders storage so = _seriesOrders[seriesId];
        for (uint256 i; i < so.count; ++i) {
            IMontionsBook.OrderView memory ov = book.orderInfo(so.ids[i]);
            if (ov.open && ov.fromHeld && ov.side == IMontionsBook.Side.Ask) {
                y += ov.qty;
            }
        }
    }

    function _markSeries(bytes32 seriesId) internal view returns (uint256) {
        IMontionsBook.SeriesInfo memory info;
        try book.seriesInfo(seriesId) returns (IMontionsBook.SeriesInfo memory got) {
            info = got;
        } catch {
            return 0;
        }
        (uint256 y, uint256 n) = _balances(seriesId, info);
        if (y == 0 && n == 0) return 0;

        if (info.status == IMontionsBook.Status.Resolved) {
            uint256 payout = (info.yes ? y : n) * UNIT;
            return _capPool(seriesId, payout);
        }
        if (info.status == IMontionsBook.Status.Void) {
            uint256 payout = (y + n) * UNIT / 2;
            return _capPool(seriesId, payout);
        }
        if (info.status != IMontionsBook.Status.Open) return 0;

        uint8 fairTick;
        try quoter.fair(seriesId) returns (uint8 t, uint256, uint256, uint256) {
            fairTick = t;
        } catch {}
        (uint8 bidTick,, uint8 askTick,) = book.bestBidAsk(seriesId);
        return _markOpen(y, n, fairTick, bidTick, askTick);
    }

    function _markOpen(uint256 y, uint256 n, uint8 fairTick, uint8 bidTick, uint8 askTick)
        internal
        pure
        returns (uint256 value)
    {
        uint256 paired = y < n ? y : n;
        value = paired * UNIT;
        y -= paired;
        n -= paired;
        if (y != 0) {
            uint256 m;
            if (bidTick != 0) {
                m = bidTick;
                if (fairTick != 0 && fairTick < m) m = fairTick;
            }
            value += y * m * TICK_UNIT;
        }
        if (n != 0) {
            uint256 m;
            if (askTick != 0) {
                m = TICKS - askTick;
                if (fairTick != 0) {
                    uint256 fairNo = TICKS - fairTick;
                    if (fairNo < m) m = fairNo;
                }
            }
            value += n * m * TICK_UNIT;
        }
    }

    function _capPool(bytes32 seriesId, uint256 payout) internal view returns (uint256) {
        uint256 p = book.pool(seriesId);
        return payout < p ? payout : p;
    }

    function _worstCaseInventory() internal view returns (uint256 exp) {
        uint256 n = _activeSeries.length;
        for (uint256 i; i < n; ++i) {
            bytes32 seriesId = _activeSeries[i];
            IMontionsBook.SeriesInfo memory info;
            try book.seriesInfo(seriesId) returns (IMontionsBook.SeriesInfo memory got) {
                info = got;
            } catch {
                continue;
            }
            (uint256 y, uint256 noQty) = _balances(seriesId, info);
            uint256 unpaired = y > noQty ? y - noQty : noQty - y;
            exp += unpaired * UNIT;
        }
    }
}
