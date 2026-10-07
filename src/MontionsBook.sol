// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMontionsBook} from "./interfaces/IMontionsBook.sol";
import {IResolver} from "./interfaces/IResolver.sol";
import {OutcomeToken1155} from "./libs/OutcomeToken1155.sol";
import {TickBitmap} from "./libs/TickBitmap.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

/// @title MontionsBook
/// @notice Fully collateralized binary outcome series and onchain price-time CLOB.
/// @dev Matching and internal outcome-token movements make no external calls.
contract MontionsBook is IMontionsBook, OutcomeToken1155, ReentrancyGuard, Multicallable {
    using TickBitmap for uint128;

    /// @notice Collateral units paid per winning contract.
    uint256 public constant override UNIT = 1_000_000;
    /// @notice Collateral units per price tick.
    uint256 public constant override TICK_UNIT = 10_000;
    /// @notice Number of ticks in a full YES price.
    uint256 public constant override TICKS = 100;
    /// @notice Minimum series duration in seconds.
    uint64 public constant override MIN_DURATION = 120;
    /// @notice Maximum series duration in seconds.
    uint64 public constant override MAX_DURATION = 90 days;
    /// @notice Delay after expiry before a not-ready resolver causes a void.
    uint64 public constant override VOID_GRACE = 2 days;
    uint16 private constant _DEFAULT_MAX_FILLS = 32;
    uint16 private constant _MAX_FILLS = 256;
    uint64 private constant _MAX_ORDER_QTY = (uint64(1) << 40) - 1;
    uint8 private constant _TRADE_RING_SIZE = 64;
    uint256 private constant _RESOLVE_GAS = 500_000;

    /// @notice Six-decimal collateral token deposited into the Book.
    address public immutable override collateral;
    /// @notice Administrator limited to resolver and fee configuration.
    address public override owner;
    /// @notice Taker fee in basis points, capped at 100.
    uint16 public override takerFeeBps;
    /// @notice Accrued fee collateral awaiting withdrawal.
    uint256 public override protocolFees;
    /// @notice Destination used by permissionless fee withdrawal.
    address public feeRecipient;

    /// @notice User free collateral available for orders and withdrawal.
    mapping(address user => uint256 amount) public override cash;
    /// @notice User collateral escrowed in open write or bid orders.
    mapping(address user => uint256 amount) public override lockedCash;
    /// @notice Resolver allowlist controlled by the owner.
    mapping(address resolver => bool allowed) public override resolverAllowed;
    /// @notice Collateral backing outcome tokens for each series.
    mapping(bytes32 seriesId => uint256 amount) public override pool;

    mapping(bytes32 seriesId => SeriesInfo info) private _series;
    bytes32[] private _seriesList;

    struct StoredOrder {
        address maker;
        bytes32 seriesId;
        uint64 qty;
        uint64 origQty;
        uint64 placedAt;
        uint64 prev;
        uint64 next;
        uint8 tick;
        Side side;
        bool fromHeld;
        bool open;
    }

    struct TickLevel {
        uint64 head;
        uint64 tail;
        uint128 qty;
    }

    mapping(uint64 orderId => StoredOrder order) private _orders;
    mapping(address user => uint64[] ids) private _userOrders;
    mapping(bytes32 seriesId => mapping(uint8 tick => TickLevel level)) private _bidLevels;
    mapping(bytes32 seriesId => mapping(uint8 tick => TickLevel level)) private _askLevels;
    mapping(bytes32 seriesId => uint128 bitmap) private _bidBitmap;
    mapping(bytes32 seriesId => uint128 bitmap) private _askBitmap;
    /// @notice Highest order id ever assigned; ids start at one.
    uint64 public override orderCount;

    mapping(bytes32 seriesId => TradeView[64] trades) private _tradeRing;
    mapping(bytes32 seriesId => uint8 nextIndex) private _tradeNext;
    mapping(bytes32 seriesId => uint8 count) private _tradeCount;
    mapping(bytes32 seriesId => uint8 tick) private _lastTradeTick;
    mapping(bytes32 seriesId => uint256 contractsTraded) private _volume;

    error UnauthorizedOwner();
    error ResolverValidationFailed();
    error BadFeeRecipient();
    error NotAuthorized();
    error ZeroAddress();
    error DataTooLong(uint256 length);
    error MaxFillsTooHigh(uint16 maxFills);
    error CollateralTransferMismatch(uint256 expected, uint256 received);

    /// @notice Deploys the Book for a collateral token and initial administrator.
    /// @param collateral_ Six-decimal ERC20 collateral used for deposits and payouts.
    /// @param owner_ Initial administrator for resolver and fee configuration.
    constructor(address collateral_, address owner_) {
        if (collateral_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        collateral = collateral_;
        owner = owner_;
        feeRecipient = owner_;
    }

    /// @notice Allows or disallows a resolver for permissionless series creation.
    /// @param resolver Resolver contract address.
    /// @param allowed Whether the resolver may be used.
    function setResolverAllowed(address resolver, bool allowed) external override onlyOwner nonReentrant {
        if (resolver == address(0)) revert ZeroAddress();
        resolverAllowed[resolver] = allowed;
    }

    /// @notice Sets the taker fee and destination for accrued protocol fees.
    /// @param takerFeeBps_ Fee in basis points, capped at 100.
    /// @param recipient Fee recipient. Must be nonzero when fees are enabled.
    function setFee(uint16 takerFeeBps_, address recipient) external override onlyOwner nonReentrant {
        if (takerFeeBps_ > 100) revert FeeTooHigh();
        if (takerFeeBps_ != 0 && recipient == address(0)) revert BadFeeRecipient();
        takerFeeBps = takerFeeBps_;
        feeRecipient = recipient == address(0) ? owner : recipient;
    }

    /// @notice Withdraws accrued fees to the configured fee recipient.
    /// @dev Anyone may trigger the transfer, but cannot choose its destination.
    function withdrawFees() external override nonReentrant {
        uint256 amount = protocolFees;
        if (amount == 0) return;
        address recipient = feeRecipient;
        protocolFees = 0;
        SafeTransferLib.safeTransfer(collateral, recipient, amount);
    }

    /// @notice Deposits collateral into the caller's free cash account.
    /// @param amount Collateral amount in the token's smallest unit.
    function deposit(uint256 amount) external override nonReentrant {
        _depositCollateral(msg.sender, amount);
    }

    /// @notice Deposits collateral using an EIP-2612 permit in the same transaction.
    /// @param amount Collateral amount in the token's smallest unit.
    /// @param deadline Permit expiry timestamp.
    /// @param v Signature recovery id.
    /// @param r Signature component.
    /// @param s Signature component.
    function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
        nonReentrant
    {
        IERC20Permit(collateral).permit(msg.sender, address(this), amount, deadline, v, r, s);
        _depositCollateral(msg.sender, amount);
    }

    /// @notice Withdraws free collateral from the caller's cash account.
    /// @param amount Collateral amount in the token's smallest unit.
    function withdraw(uint256 amount) external override nonReentrant {
        uint256 available = cash[msg.sender];
        if (available < amount) revert InsufficientCash();
        unchecked {
            cash[msg.sender] = available - amount;
        }
        SafeTransferLib.safeTransfer(collateral, msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Computes the deterministic id for resolver data and expiry.
    /// @param resolver Resolver contract.
    /// @param data Resolver-specific series description.
    /// @param expiry Unix timestamp when trading expires.
    /// @return seriesId Deterministic series id.
    function seriesIdOf(address resolver, bytes calldata data, uint64 expiry)
        external
        pure
        override
        returns (bytes32 seriesId)
    {
        return keccak256(abi.encode(resolver, data, expiry));
    }

    /// @notice Creates a permissionless market using an owner-approved resolver.
    /// @param resolver Resolver contract.
    /// @param data Resolver-specific market definition.
    /// @param expiry Unix timestamp when trading expires.
    /// @return seriesId Newly created series id.
    function createSeries(address resolver, bytes calldata data, uint64 expiry)
        external
        override
        nonReentrant
        returns (bytes32 seriesId)
    {
        if (data.length > 512) revert DataTooLong(data.length);
        if (!resolverAllowed[resolver] || resolver.code.length == 0) revert ResolverNotAllowed();
        if (expiry < block.timestamp + MIN_DURATION || expiry > block.timestamp + MAX_DURATION) revert BadExpiry();
        try IResolver(resolver).validate(data, expiry) {}
        catch {
            revert ResolverValidationFailed();
        }

        seriesId = keccak256(abi.encode(resolver, data, expiry));
        if (_series[seriesId].status != Status.None) revert SeriesExists();

        uint256 yesId = uint256(keccak256(abi.encode(seriesId, "YES")));
        uint256 noId = uint256(keccak256(abi.encode(seriesId, "NO")));
        _series[seriesId] = SeriesInfo({
            resolver: resolver,
            data: data,
            expiry: expiry,
            status: Status.Open,
            yes: false,
            yesId: yesId,
            noId: noId,
            createdAt: uint64(block.timestamp)
        });
        _seriesList.push(seriesId);
        emit SeriesCreated(seriesId, resolver, expiry, yesId, noId);
    }

    /// @notice Returns stored metadata for a series.
    /// @param seriesId Series identifier.
    /// @return info Resolver data, status, expiry, and outcome-token ids.
    function seriesInfo(bytes32 seriesId) external view override returns (SeriesInfo memory info) {
        info = _series[seriesId];
        if (info.status == Status.None) revert SeriesUnknown();
    }

    /// @notice Returns the number of created series.
    /// @return count Total number of series.
    function seriesCount() external view override returns (uint256 count) {
        return _seriesList.length;
    }

    /// @notice Returns a series id by its zero-based creation index.
    /// @param index Series index.
    /// @return seriesId Series identifier.
    function seriesIdAt(uint256 index) external view override returns (bytes32 seriesId) {
        if (index >= _seriesList.length) revert SeriesUnknown();
        return _seriesList[index];
    }

    /// @notice Pages the series ids in creation order.
    /// @param offset First zero-based series index.
    /// @param limit Maximum number of ids to return.
    /// @return ids Series identifiers.
    function seriesIds(uint256 offset, uint256 limit) external view override returns (bytes32[] memory ids) {
        uint256 count = _seriesList.length;
        if (offset >= count || limit == 0) return new bytes32[](0);
        uint256 length = count - offset;
        if (length > limit) length = limit;
        ids = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            ids[i] = _seriesList[offset + i];
        }
    }

    /// @notice Places a limit order and applies maker price-time priority.
    /// @dev A Bid with `fromHeld=true` escrows NO plus bid-limit cash to acquire YES and merge the pair;
    ///      it earns UNIT minus the resting YES tick per fill. Against a write-Ask, the writer receives
    ///      newly minted NO while the acquired YES and escrowed NO are burned together; against a held-YES
    ///      Ask, both existing legs are burned and the pool releases UNIT. The taker fee is one ceil on
    ///      collateral consumed across all fills. Bids and write-Asks reserve the maximum fee up front and
    ///      release the unused reserve when the taker phase ends; held-token sellers pay from proceeds.
    ///      At the `maxFills` bound, a still-crossing GTC remainder is refunded and returned with
    ///      `resting == 0`; only a non-crossing remainder joins the book.
    /// @param p Order series, side, limit, quantity, time-in-force, and fill bound.
    /// @return orderId Sequential id assigned to this submission.
    /// @return filled Contracts matched immediately.
    /// @return resting Contracts left open on the book.
    function placeOrder(PlaceParams calldata p)
        external
        override
        nonReentrant
        returns (uint64 orderId, uint64 filled, uint64 resting)
    {
        _prepareOrder(p);
        orderId = _recordIncoming(p);
        uint256 takerCollateralConsumed;
        (filled, resting, takerCollateralConsumed) = _matchOrder(p);
        resting = _finishIncoming(p, orderId, resting);
        _settleTakerFee(p, takerCollateralConsumed);
    }

    function _prepareOrder(PlaceParams calldata p) private {
        SeriesInfo storage info = _series[p.seriesId];
        if (info.status == Status.None) revert SeriesUnknown();
        if (info.status != Status.Open) revert SeriesNotOpen();
        if (block.timestamp >= info.expiry) revert Expired();
        if (p.tick == 0 || p.tick >= TICKS) revert BadTick();
        if (p.qty == 0 || p.qty > _MAX_ORDER_QTY) revert BadQty();
        if (p.maxFills > _MAX_FILLS) revert MaxFillsTooHigh(p.maxFills);

        if (p.tif == TIF.POST_ONLY && _wouldCross(p.seriesId, p.side, p.tick)) revert WouldCross();

        uint256 escrow = _orderEscrow(p.side, p.tick, p.qty, p.fromHeld);
        uint256 feeReserve = p.fromHeld ? 0 : _feeFor(escrow);
        uint256 requiredCash = escrow + feeReserve;
        uint256 free = cash[msg.sender];
        if (free < requiredCash) revert InsufficientCash();

        if (p.fromHeld) {
            uint256 tokenId = p.side == Side.Bid ? info.noId : info.yesId;
            if (_outcomeBalance(msg.sender, tokenId) < p.qty) revert InsufficientTokens();
            _transferOutcome(msg.sender, address(this), tokenId, p.qty);
        }
        if (requiredCash != 0) {
            unchecked {
                cash[msg.sender] = free - requiredCash;
            }
            lockedCash[msg.sender] += requiredCash;
        }
    }

    function _recordIncoming(PlaceParams calldata p) private returns (uint64 orderId) {
        orderId = ++orderCount;
        _orders[orderId] = StoredOrder({
            maker: msg.sender,
            seriesId: p.seriesId,
            qty: p.qty,
            origQty: p.qty,
            placedAt: uint64(block.timestamp),
            prev: 0,
            next: 0,
            tick: p.tick,
            side: p.side,
            fromHeld: p.fromHeld,
            open: false
        });
        _userOrders[msg.sender].push(orderId);
        emit OrderPlaced(orderId, p.seriesId, msg.sender, p.side, p.tick, p.qty, p.fromHeld);
    }

    function _matchOrder(PlaceParams calldata p)
        private
        returns (uint64 filled, uint64 remaining, uint256 takerCollateralConsumed)
    {
        remaining = p.qty;
        uint16 maxFills = p.maxFills == 0 ? _DEFAULT_MAX_FILLS : p.maxFills;
        uint16 attempts;
        while (remaining != 0 && attempts < maxFills) {
            (uint8 makerTick, uint64 makerId) = _bestCrossingOrder(p.seriesId, p.side, p.tick);
            if (makerId == 0) break;

            StoredOrder storage maker = _orders[makerId];
            if (maker.maker == msg.sender) {
                _cancelResting(makerId);
                ++attempts;
                continue;
            }
            uint64 fillQty = _matchCandidate(p, makerId, makerTick, remaining);
            remaining -= fillQty;
            filled += fillQty;
            takerCollateralConsumed += _takerCollateralConsumed(p, makerTick, fillQty);
            ++attempts;
        }
    }

    function _finishIncoming(PlaceParams calldata p, uint64 orderId, uint64 remaining)
        private
        returns (uint64 resting)
    {
        StoredOrder storage incoming = _orders[orderId];
        incoming.qty = remaining;
        if (remaining == 0) return 0;

        bool mayRest = p.tif == TIF.GTC || p.tif == TIF.POST_ONLY;
        bool stillCrosses = _wouldCross(p.seriesId, p.side, p.tick);
        if (mayRest && !stillCrosses) {
            incoming.open = true;
            _enqueue(orderId);
            return remaining;
        }

        _refundIncoming(p, remaining);
        incoming.qty = 0;
        incoming.open = false;
        emit OrderCancelled(orderId, p.seriesId, remaining);
        return 0;
    }

    /// @notice Cancels one open order owned by the caller, including after expiry.
    /// @param orderId Order to cancel.
    function cancelOrder(uint64 orderId) external override nonReentrant {
        StoredOrder storage order = _orders[orderId];
        if (order.maker == address(0)) revert OrderNotOpen();
        if (order.maker != msg.sender) revert NotOrderOwner();
        if (!order.open) revert OrderNotOpen();
        _cancelResting(orderId);
    }

    /// @notice Cancels several caller-owned orders atomically.
    /// @param orderIds Order ids to cancel.
    function cancelOrders(uint64[] calldata orderIds) external override nonReentrant {
        for (uint256 i; i < orderIds.length; ++i) {
            StoredOrder storage order = _orders[orderIds[i]];
            if (order.maker == address(0)) revert OrderNotOpen();
            if (order.maker != msg.sender) revert NotOrderOwner();
            if (!order.open) revert OrderNotOpen();
            _cancelResting(orderIds[i]);
        }
    }

    /// @notice Splits collateral into one YES and one NO token per contract.
    /// @param seriesId Open series id.
    /// @param qty Number of paired contracts to create.
    function split(bytes32 seriesId, uint64 qty) external override nonReentrant {
        SeriesInfo storage info = _series[seriesId];
        if (info.status == Status.None) revert SeriesUnknown();
        if (info.status != Status.Open) revert SeriesNotOpen();
        if (block.timestamp >= info.expiry) revert Expired();
        if (qty == 0 || qty > _MAX_ORDER_QTY) revert BadQty();
        uint256 amount = uint256(qty) * UNIT;
        uint256 free = cash[msg.sender];
        if (free < amount) revert InsufficientCash();
        unchecked {
            cash[msg.sender] = free - amount;
        }
        pool[seriesId] += amount;
        _mintOutcome(msg.sender, info.yesId, qty);
        _mintOutcome(msg.sender, info.noId, qty);
        emit Split(seriesId, msg.sender, qty);
    }

    /// @notice Burns equal YES and NO amounts to return their paired collateral.
    /// @param seriesId Open series id.
    /// @param qty Number of pairs to merge.
    function merge(bytes32 seriesId, uint64 qty) external override nonReentrant {
        SeriesInfo storage info = _series[seriesId];
        if (info.status == Status.None) revert SeriesUnknown();
        if (info.status != Status.Open) revert SeriesNotOpen();
        if (qty == 0 || qty > _MAX_ORDER_QTY) revert BadQty();
        uint256 amount = uint256(qty) * UNIT;
        if (_outcomeBalance(msg.sender, info.yesId) < qty || _outcomeBalance(msg.sender, info.noId) < qty) {
            revert InsufficientTokens();
        }
        if (pool[seriesId] < amount) revert InsufficientCash();
        _burnOutcome(msg.sender, info.yesId, qty);
        _burnOutcome(msg.sender, info.noId, qty);
        pool[seriesId] -= amount;
        cash[msg.sender] += amount;
        emit Merge(seriesId, msg.sender, qty);
    }

    /// @notice Resolves an expired series or voids it after the resolver grace period.
    /// @param seriesId Expired series id.
    function resolve(bytes32 seriesId) external override nonReentrant {
        SeriesInfo storage info = _series[seriesId];
        if (info.status == Status.None) revert SeriesUnknown();
        if (info.status != Status.Open) revert AlreadySettled();
        if (block.timestamp <= info.expiry) revert NotExpired();

        (bool success, bytes memory result) =
            info.resolver.staticcall{gas: _RESOLVE_GAS}(abi.encodeCall(IResolver.resolve, (info.data, info.expiry)));
        bool ready;
        bool yes;
        if (success && result.length >= 64) {
            uint256 readyWord;
            uint256 yesWord;
            assembly {
                readyWord := mload(add(result, 0x20))
                yesWord := mload(add(result, 0x40))
            }
            if (readyWord <= 1 && yesWord <= 1) {
                ready = readyWord == 1;
                yes = yesWord == 1;
            }
        }

        if (ready) {
            info.status = Status.Resolved;
            info.yes = yes;
            emit SeriesResolved(seriesId, yes);
            return;
        }
        if (block.timestamp < uint256(info.expiry) + VOID_GRACE) revert NotExpired();
        info.status = Status.Void;
        emit SeriesVoided(seriesId);
    }

    /// @notice Burns the caller's outcome tokens and credits the settlement payout.
    /// @param seriesId Settled series id.
    /// @param yesQty YES amount to redeem.
    /// @param noQty NO amount to redeem.
    /// @return payout Collateral credited to caller.
    function redeem(bytes32 seriesId, uint256 yesQty, uint256 noQty)
        external
        override
        nonReentrant
        returns (uint256 payout)
    {
        SeriesInfo storage info = _series[seriesId];
        if (info.status == Status.None) revert SeriesUnknown();
        if (info.status == Status.Open) revert SeriesNotOpen();
        if (yesQty == 0 && noQty == 0) revert BadQty();
        if (_outcomeBalance(msg.sender, info.yesId) < yesQty || _outcomeBalance(msg.sender, info.noId) < noQty) {
            revert InsufficientTokens();
        }

        if (info.status == Status.Resolved) {
            payout = (info.yes ? yesQty : noQty) * UNIT;
        } else {
            payout = (yesQty + noQty) * UNIT / 2;
        }
        if (pool[seriesId] < payout) revert InsufficientCash();

        if (yesQty != 0) _burnOutcome(msg.sender, info.yesId, yesQty);
        if (noQty != 0) _burnOutcome(msg.sender, info.noId, noQty);
        pool[seriesId] -= payout;
        cash[msg.sender] += payout;
        emit Redeemed(seriesId, msg.sender, yesQty, noQty, payout);
    }

    /// @notice Returns the best bid and ask prices with their aggregate quantities.
    /// @param seriesId Series to inspect.
    /// @return bidTick Highest bid tick, or zero if absent.
    /// @return bidQty Quantity at the best bid.
    /// @return askTick Lowest ask tick, or zero if absent.
    /// @return askQty Quantity at the best ask.
    function bestBidAsk(bytes32 seriesId)
        external
        view
        override
        returns (uint8 bidTick, uint64 bidQty, uint8 askTick, uint64 askQty)
    {
        bidTick = _bidBitmap[seriesId].highestSetBit();
        askTick = _askBitmap[seriesId].lowestSetBit();
        if (bidTick != 0) bidQty = uint64(_bidLevels[seriesId][bidTick].qty);
        if (askTick != 0) askQty = uint64(_askLevels[seriesId][askTick].qty);
    }

    /// @notice Returns aggregate levels best price first for one side.
    /// @param seriesId Series to inspect.
    /// @param side Bid or ask side.
    /// @param maxLevels Maximum number of nonempty levels.
    /// @return levels Aggregated quantities ordered by price priority.
    function depth(bytes32 seriesId, Side side, uint8 maxLevels)
        external
        view
        override
        returns (Level[] memory levels)
    {
        if (maxLevels == 0) return new Level[](0);
        uint128 bitmap = side == Side.Bid ? _bidBitmap[seriesId] : _askBitmap[seriesId];
        levels = new Level[](maxLevels);
        uint256 count;
        while (bitmap != 0 && count < maxLevels) {
            uint8 tick = side == Side.Bid ? bitmap.highestSetBit() : bitmap.lowestSetBit();
            uint128 qty = side == Side.Bid ? _bidLevels[seriesId][tick].qty : _askLevels[seriesId][tick].qty;
            levels[count++] = Level({tick: tick, qty: uint64(qty)});
            bitmap = bitmap.unset(tick);
        }
        assembly {
            mstore(levels, count)
        }
    }

    /// @notice Returns an order's current and original quantity plus status.
    /// @param orderId Order id.
    /// @return order Stored order metadata, or a zero-valued view for an unknown id.
    function orderInfo(uint64 orderId) external view override returns (OrderView memory order) {
        return _orderView(orderId);
    }

    /// @notice Returns the number of order ids ever assigned to a user.
    /// @param user User address.
    /// @return count Number of submitted orders.
    function userOrderCount(address user) external view override returns (uint256 count) {
        return _userOrders[user].length;
    }

    /// @notice Pages a user's orders newest first, including closed orders.
    /// @param user User address.
    /// @param offset Number of newest orders to skip.
    /// @param limit Maximum number of orders to return.
    /// @return orders Order views in descending creation order.
    function ordersOf(address user, uint256 offset, uint256 limit)
        external
        view
        override
        returns (OrderView[] memory orders)
    {
        uint256 length = _userOrders[user].length;
        if (offset >= length || limit == 0) return new OrderView[](0);
        uint256 count = length - offset;
        if (count > limit) count = limit;
        orders = new OrderView[](count);
        for (uint256 i; i < count; ++i) {
            uint64 id = _userOrders[user][length - 1 - offset - i];
            orders[i] = _orderView(id);
        }
    }

    /// @notice Returns up to `n` most recent trades for a series, newest first.
    /// @param seriesId Series to inspect.
    /// @param n Maximum number of trades, capped at the 64-entry ring size.
    /// @return trades Recent trade records.
    function recentTrades(bytes32 seriesId, uint8 n) external view override returns (TradeView[] memory trades) {
        uint8 count = _tradeCount[seriesId];
        if (n > count) n = count;
        trades = new TradeView[](n);
        uint8 next = _tradeNext[seriesId];
        for (uint8 i; i < n; ++i) {
            uint8 index = uint8((uint256(next) + _TRADE_RING_SIZE - 1 - i) & (_TRADE_RING_SIZE - 1));
            trades[i] = _tradeRing[seriesId][index];
        }
    }

    /// @notice Returns the most recent trade tick, or zero when no trade occurred.
    /// @param seriesId Series to inspect.
    /// @return tick Most recent executed tick.
    function lastTradeTick(bytes32 seriesId) external view override returns (uint8 tick) {
        return _lastTradeTick[seriesId];
    }

    /// @notice Returns lifetime contracts traded for a series.
    /// @param seriesId Series to inspect.
    /// @return contractsTraded Sum of all filled contract quantities.
    function volumeOf(bytes32 seriesId) external view override returns (uint256 contractsTraded) {
        return _volume[seriesId];
    }

    /// @notice Returns an account's outcome-token balance.
    /// @param account Account to inspect.
    /// @param id YES or NO outcome-token id.
    /// @return amount Token balance.
    function balanceOf(address account, uint256 id) external view override returns (uint256 amount) {
        if (account == address(0)) revert ZeroAddress();
        return _outcomeBalance(account, id);
    }

    /// @notice Returns balances for a batch of accounts and token ids.
    /// @param accounts Accounts to inspect.
    /// @param ids YES or NO outcome-token ids.
    /// @return amounts Corresponding token balances.
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory amounts)
    {
        if (accounts.length != ids.length) revert OutcomeArrayLengthMismatch();
        amounts = new uint256[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            amounts[i] = _outcomeBalance(accounts[i], ids[i]);
        }
    }

    /// @notice Returns the total supply of an outcome-token id.
    /// @param id YES or NO outcome-token id.
    /// @return amount Total supply.
    function totalSupply(uint256 id) external view override returns (uint256 amount) {
        return _outcomeSupply(id);
    }

    /// @notice Transfers outcome tokens and calls a receiver hook for contract recipients.
    /// @param from Source token holder.
    /// @param to Destination token holder.
    /// @param id YES or NO outcome-token id.
    /// @param amount Token amount.
    /// @param data Opaque receiver callback data.
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data)
        external
        override
        nonReentrant
    {
        if (msg.sender != from && !_outcomeApproved(from, msg.sender)) revert NotAuthorized();
        _transferOutcome(from, to, id, amount);
        _checkOutcomeReceiver(from, to, id, amount, data);
    }

    /// @notice Transfers outcome-token batches and calls a batch receiver hook for contract recipients.
    /// @param from Source token holder.
    /// @param to Destination token holder.
    /// @param ids YES or NO outcome-token ids.
    /// @param amounts Token amounts corresponding to `ids`.
    /// @param data Opaque receiver callback data.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external nonReentrant {
        if (msg.sender != from && !_outcomeApproved(from, msg.sender)) {
            revert NotAuthorized();
        }
        _transferOutcomeBatch(from, to, ids, amounts);
        _checkOutcomeBatchReceiver(from, to, ids, amounts, data);
    }

    /// @notice Grants or revokes an operator's right to transfer caller tokens.
    /// @param operator Operator address.
    /// @param approved True to approve, false to revoke.
    function setApprovalForAll(address operator, bool approved) external override nonReentrant {
        if (operator == address(0)) revert ZeroAddress();
        if (operator == msg.sender) revert NotAuthorized();
        _setOutcomeApproval(operator, approved);
    }

    /// @notice Returns whether an operator is approved for an account.
    /// @param account Token owner.
    /// @param operator Potential operator.
    /// @return approved True if the operator is approved.
    function isApprovedForAll(address account, address operator) external view override returns (bool approved) {
        return _outcomeApproved(account, operator);
    }

    /// @notice Reports ERC165 and ERC1155 interface support.
    /// @param interfaceId Interface identifier to query.
    /// @return supported True for ERC165 and ERC1155.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool supported) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0xd9b67a26;
    }

    /// @notice Batches Book calls with the caller preserved by Solady Multicallable.
    /// @param data Encoded calls to this contract.
    /// @return results Return data from each call.
    function multicall(bytes[] calldata data)
        public
        payable
        override(IMontionsBook, Multicallable)
        returns (bytes[] memory results)
    {
        return Multicallable.multicall(data);
    }

    function _executeFill(PlaceParams calldata p, uint64 makerId, uint64 qty, uint8 price, bool takerIsBuyer) private {
        StoredOrder storage maker = _orders[makerId];
        uint256 premium = uint256(qty) * price * TICK_UNIT;

        if (takerIsBuyer) {
            if (p.fromHeld) _executeCloseNoBid(p, maker, qty, price, premium);
            else _executeRegularBid(p, maker, qty, price, premium);
        } else if (maker.fromHeld) {
            if (p.fromHeld) _executeHeldAskAgainstCloseNo(p, maker, qty, premium);
            else _executeWriteAskAgainstCloseNo(p, maker, qty, price, premium);
        } else if (p.fromHeld) {
            _executeHeldAsk(p, maker, qty, premium);
        } else {
            _executeWriteAsk(p, maker, qty, price, premium);
        }
    }

    function _executeRegularBid(
        PlaceParams calldata p,
        StoredOrder storage maker,
        uint64 qty,
        uint8 price,
        uint256 premium
    ) private {
        uint256 reserved = uint256(qty) * p.tick * TICK_UNIT;
        lockedCash[msg.sender] -= reserved;
        cash[msg.sender] += reserved - premium;

        if (maker.fromHeld) {
            cash[maker.maker] += premium;
            _transferOutcome(address(this), msg.sender, _series[p.seriesId].yesId, qty);
        } else {
            lockedCash[maker.maker] -= uint256(qty) * (TICKS - price) * TICK_UNIT;
            pool[p.seriesId] += uint256(qty) * UNIT;
            _mintOutcome(msg.sender, _series[p.seriesId].yesId, qty);
            _mintOutcome(maker.maker, _series[p.seriesId].noId, qty);
        }
    }

    /// @dev Close-NO pays the bid premium to a held-YES seller or creates and immediately
    ///      merges a written pair. In either case the escrowed NO and acquired YES are burned;
    ///      the pool and both supplies return to their pre-fill values.
    function _executeCloseNoBid(
        PlaceParams calldata p,
        StoredOrder storage maker,
        uint64 qty,
        uint8 price,
        uint256 premium
    ) private {
        SeriesInfo storage info = _series[p.seriesId];
        uint256 reserved = uint256(qty) * p.tick * TICK_UNIT;
        uint256 payout = uint256(qty) * UNIT;
        lockedCash[msg.sender] -= reserved;
        cash[msg.sender] += reserved - premium;

        if (maker.fromHeld) {
            cash[maker.maker] += premium;
            _burnOutcome(address(this), info.yesId, qty);
        } else {
            lockedCash[maker.maker] -= uint256(qty) * (TICKS - price) * TICK_UNIT;
            pool[p.seriesId] += payout;
            _mintOutcome(msg.sender, info.yesId, qty);
            _mintOutcome(maker.maker, info.noId, qty);
            _burnOutcome(msg.sender, info.yesId, qty);
        }
        _burnOutcome(address(this), info.noId, qty);
        pool[p.seriesId] -= payout;
        cash[msg.sender] += payout;
    }

    function _executeHeldAsk(PlaceParams calldata p, StoredOrder storage maker, uint64 qty, uint256 premium) private {
        lockedCash[maker.maker] -= premium;
        cash[msg.sender] += premium;
        _transferOutcome(address(this), maker.maker, _series[p.seriesId].yesId, qty);
    }

    function _executeWriteAsk(
        PlaceParams calldata p,
        StoredOrder storage maker,
        uint64 qty,
        uint8 price,
        uint256 premium
    ) private {
        lockedCash[maker.maker] -= premium;
        uint256 reserved = uint256(qty) * (TICKS - p.tick) * TICK_UNIT;
        uint256 writeCollateral = uint256(qty) * (TICKS - price) * TICK_UNIT;
        lockedCash[msg.sender] -= reserved;
        cash[msg.sender] += reserved - writeCollateral;
        pool[p.seriesId] += uint256(qty) * UNIT;
        _mintOutcome(maker.maker, _series[p.seriesId].yesId, qty);
        _mintOutcome(msg.sender, _series[p.seriesId].noId, qty);
    }

    function _executeHeldAskAgainstCloseNo(
        PlaceParams calldata p,
        StoredOrder storage maker,
        uint64 qty,
        uint256 premium
    ) private {
        SeriesInfo storage info = _series[p.seriesId];
        uint256 payout = uint256(qty) * UNIT;
        lockedCash[maker.maker] -= premium;
        cash[msg.sender] += premium;
        _burnOutcome(address(this), info.yesId, qty);
        _burnOutcome(address(this), info.noId, qty);
        pool[p.seriesId] -= payout;
        cash[maker.maker] += payout;
    }

    function _executeWriteAskAgainstCloseNo(
        PlaceParams calldata p,
        StoredOrder storage maker,
        uint64 qty,
        uint8 price,
        uint256 premium
    ) private {
        SeriesInfo storage info = _series[p.seriesId];
        uint256 payout = uint256(qty) * UNIT;
        uint256 reserved = uint256(qty) * (TICKS - p.tick) * TICK_UNIT;
        uint256 writeCollateral = uint256(qty) * (TICKS - price) * TICK_UNIT;
        lockedCash[maker.maker] -= premium;
        lockedCash[msg.sender] -= reserved;
        cash[msg.sender] += reserved - writeCollateral;
        pool[p.seriesId] += payout;
        _mintOutcome(maker.maker, info.yesId, qty);
        _mintOutcome(msg.sender, info.noId, qty);
        _burnOutcome(maker.maker, info.yesId, qty);
        _burnOutcome(address(this), info.noId, qty);
        pool[p.seriesId] -= payout;
        cash[maker.maker] += payout;
    }

    function _matchCandidate(PlaceParams calldata p, uint64 makerId, uint8 makerTick, uint64 remaining)
        private
        returns (uint64 fillQty)
    {
        StoredOrder storage maker = _orders[makerId];
        fillQty = maker.qty < remaining ? maker.qty : remaining;
        bool takerIsBuyer = p.side == Side.Bid;
        address makerAddress = maker.maker;
        _executeFill(p, makerId, fillQty, makerTick, takerIsBuyer);
        _consumeResting(makerId, fillQty);
        _recordTrade(p.seriesId, makerTick, fillQty, takerIsBuyer);
        emit Trade(p.seriesId, makerId, makerAddress, msg.sender, makerTick, fillQty, takerIsBuyer);
    }

    function _takerCollateralConsumed(PlaceParams calldata p, uint8 price, uint64 qty) private pure returns (uint256) {
        uint256 perContract;
        if (p.side == Side.Bid) perContract = p.fromHeld ? TICKS - price : price;
        else perContract = p.fromHeld ? price : TICKS - price;
        return uint256(qty) * perContract * TICK_UNIT;
    }

    function _settleTakerFee(PlaceParams calldata p, uint256 consumed) private {
        uint256 fee = _feeFor(consumed);
        if (p.fromHeld) {
            if (fee != 0) {
                uint256 free = cash[msg.sender];
                if (free < fee) revert InsufficientCash();
                unchecked {
                    cash[msg.sender] = free - fee;
                }
                protocolFees += fee;
            }
            return;
        }

        uint256 reserve = _feeFor(_orderEscrow(p.side, p.tick, p.qty, false));
        if (reserve != 0) {
            lockedCash[msg.sender] -= reserve;
            cash[msg.sender] += reserve - fee;
        }
        protocolFees += fee;
    }

    function _refundIncoming(PlaceParams calldata p, uint64 qty) private {
        uint256 amount = _orderEscrow(p.side, p.tick, qty, p.fromHeld);
        if (amount != 0) {
            lockedCash[msg.sender] -= amount;
            cash[msg.sender] += amount;
        }
        if (p.fromHeld) {
            uint256 tokenId = p.side == Side.Bid ? _series[p.seriesId].noId : _series[p.seriesId].yesId;
            _transferOutcome(address(this), msg.sender, tokenId, qty);
        }
    }

    function _cancelResting(uint64 orderId) private {
        StoredOrder storage order = _orders[orderId];
        uint64 qty = order.qty;
        uint256 amount = _orderEscrow(order.side, order.tick, qty, order.fromHeld);
        if (amount != 0) {
            lockedCash[order.maker] -= amount;
            cash[order.maker] += amount;
        }
        if (order.fromHeld) {
            SeriesInfo storage info = _series[order.seriesId];
            uint256 tokenId = order.side == Side.Bid ? info.noId : info.yesId;
            _transferOutcome(address(this), order.maker, tokenId, qty);
        }
        _removeFromLevel(orderId, qty);
        order.qty = 0;
        order.open = false;
        emit OrderCancelled(orderId, order.seriesId, qty);
    }

    function _consumeResting(uint64 orderId, uint64 qty) private {
        StoredOrder storage order = _orders[orderId];
        TickLevel storage level = _level(order.seriesId, order.side, order.tick);
        level.qty -= uint128(qty);
        order.qty -= qty;
        if (order.qty == 0) {
            _unlink(orderId, level);
            order.open = false;
        }
        if (level.qty == 0) _setOccupied(order.seriesId, order.side, order.tick, false);
    }

    function _removeFromLevel(uint64 orderId, uint64 qty) private {
        StoredOrder storage order = _orders[orderId];
        TickLevel storage level = _level(order.seriesId, order.side, order.tick);
        level.qty -= uint128(qty);
        _unlink(orderId, level);
        if (level.qty == 0) _setOccupied(order.seriesId, order.side, order.tick, false);
    }

    function _enqueue(uint64 orderId) private {
        StoredOrder storage order = _orders[orderId];
        TickLevel storage level = _level(order.seriesId, order.side, order.tick);
        if (level.qty == 0) _setOccupied(order.seriesId, order.side, order.tick, true);
        uint64 oldTail = level.tail;
        order.prev = oldTail;
        order.next = 0;
        if (oldTail == 0) level.head = orderId;
        else _orders[oldTail].next = orderId;
        level.tail = orderId;
        level.qty += uint128(order.qty);
    }

    function _unlink(uint64 orderId, TickLevel storage level) private {
        StoredOrder storage order = _orders[orderId];
        uint64 prev = order.prev;
        uint64 next = order.next;
        if (prev == 0) level.head = next;
        else _orders[prev].next = next;
        if (next == 0) level.tail = prev;
        else _orders[next].prev = prev;
        order.prev = 0;
        order.next = 0;
    }

    function _recordTrade(bytes32 seriesId, uint8 tick, uint64 qty, bool takerIsBuyer) private {
        uint8 index = _tradeNext[seriesId];
        _tradeRing[seriesId][index] =
            TradeView({ts: uint64(block.timestamp), tick: tick, qty: qty, takerIsBuyer: takerIsBuyer});
        _tradeNext[seriesId] = (index + 1) & (_TRADE_RING_SIZE - 1);
        if (_tradeCount[seriesId] < _TRADE_RING_SIZE) ++_tradeCount[seriesId];
        _lastTradeTick[seriesId] = tick;
        _volume[seriesId] += qty;
    }

    function _wouldCross(bytes32 seriesId, Side side, uint8 tick) private view returns (bool) {
        if (side == Side.Bid) {
            uint8 ask = _askBitmap[seriesId].lowestSetBit();
            return ask != 0 && ask <= tick;
        }
        uint8 bid = _bidBitmap[seriesId].highestSetBit();
        return bid != 0 && bid >= tick;
    }

    function _bestCrossingOrder(bytes32 seriesId, Side takerSide, uint8 limit)
        private
        view
        returns (uint8 tick, uint64 orderId)
    {
        if (takerSide == Side.Bid) {
            tick = _askBitmap[seriesId].lowestSetBit();
            if (tick != 0 && tick <= limit) orderId = _askLevels[seriesId][tick].head;
        } else {
            tick = _bidBitmap[seriesId].highestSetBit();
            if (tick != 0 && tick >= limit) orderId = _bidLevels[seriesId][tick].head;
        }
        if (orderId == 0) tick = 0;
    }

    function _orderEscrow(Side side, uint8 tick, uint64 qty, bool fromHeld) private pure returns (uint256) {
        if (fromHeld && side == Side.Ask) return 0;
        uint256 perContract = side == Side.Bid ? tick : TICKS - tick;
        return uint256(qty) * perContract * TICK_UNIT;
    }

    function _feeFor(uint256 collateralConsumed) private view returns (uint256) {
        uint16 bps = takerFeeBps;
        if (bps == 0 || collateralConsumed == 0) return 0;
        return (collateralConsumed * bps + 9_999) / 10_000;
    }

    function _depositCollateral(address account, uint256 amount) private {
        uint256 beforeBalance = IERC20Balance(collateral).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(collateral, account, address(this), amount);
        uint256 afterBalance = IERC20Balance(collateral).balanceOf(address(this));
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (received != amount) revert CollateralTransferMismatch(amount, received);
        cash[account] += amount;
        emit Deposit(account, amount);
    }

    function _level(bytes32 seriesId, Side side, uint8 tick) private view returns (TickLevel storage level) {
        if (side == Side.Bid) return _bidLevels[seriesId][tick];
        return _askLevels[seriesId][tick];
    }

    function _setOccupied(bytes32 seriesId, Side side, uint8 tick, bool occupied) private {
        if (side == Side.Bid) {
            _bidBitmap[seriesId] = occupied ? _bidBitmap[seriesId].set(tick) : _bidBitmap[seriesId].unset(tick);
        } else {
            _askBitmap[seriesId] = occupied ? _askBitmap[seriesId].set(tick) : _askBitmap[seriesId].unset(tick);
        }
    }

    function _orderView(uint64 id) private view returns (OrderView memory view_) {
        StoredOrder storage order = _orders[id];
        view_ = OrderView({
            id: id,
            maker: order.maker,
            seriesId: order.seriesId,
            side: order.side,
            tick: order.tick,
            fromHeld: order.fromHeld,
            qty: order.qty,
            origQty: order.origQty,
            placedAt: order.placedAt,
            open: order.open
        });
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner();
        _;
    }
}

    interface IERC20Permit {
        function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
            external;
    }

    interface IERC20Balance {
        function balanceOf(address account) external view returns (uint256);
    }
