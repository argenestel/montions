// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title SpotPool
/// @notice MOCK/DEMO constant-product AMM used as an onchain TWAP price source.
/// @dev HONESTY: pool-TWAP oracles are manipulable at low liquidity. This demo is intended
///      to be seeded with deep reserves; it is NOT manipulation-resistant and MUST NOT be
///      treated as a production oracle. Labelled MOCK/DEMO.
///
///      An attacker who moves the pool in the last seconds of an idle window influences
///      the TWAP (the last observation's forward price is held until the next write).
///      Depth and a longer window mitigate this; they never eliminate it.
///
///      Quote token is tUSDC (6 decimals). Base token is an 18-decimal MOCK asset.
///      `priceWad` = USD per 1 whole base token, 1e18-scaled:
///          priceWad = quoteReserve * 10^30 / baseReserve
///      Reverts `EmptyReserves` when either reserve is zero.
///
///      Swap fee is 0.30% (30 bps, Uniswap V2-style 997/1000) taken on input and accrued
///      in reserves (k = baseReserve * quoteReserve on raw token units is non-decreasing).
///      Liquidity adds do not charge a fee. Either side of `addLiquidity` may be zero so
///      the demo owner can reprice without a swap. **Every `addLiquidity` that starts from
///      or results in a priced pool writes an observation**: the pre-change price is
///      recorded first (so the owner cannot silently rewrite TWAP history), reserves are
///      updated, then the last observation's forward `price` is set to the post-change
///      spot. A first seed (empty → priced) writes a single observation of the new price.
///
///      Observations: an 8192-slot ring. At most ONE observation per `block.timestamp`.
///      A second write at the same timestamp (swap, checkpoint, or addLiquidity) updates
///      that observation's `price` in place and never advances the ring. When the ring
///      is full, the next new-timestamp write overwrites the oldest sample
///      (`nextObsIndex`); `observationCount` keeps growing so consumers can detect wrap.
///
///      `cumPrice` is the cumulative `price * dt` in 1e18 scale. **Unchecked wrap of
///      `cumPrice` at 2^224 is intended** — consumers MUST difference nearby observations
///      with wrapping uint224 subtraction (the delta over any realistic window fits in
///      uint224). Interpolation uses wrapping add. `price` is stored as uint192; realistic
///      wad prices fit with huge margin (uint192 max ≈ 6.27e57). uint32 `ts` truncates
///      `block.timestamp` (Y2106); a backwards time jump reverts on `dt` subtraction.
///
///      Each observation's `price` is forward-looking: it is the spot after the write
///      (and after any later same-timestamp swaps / checkpoints / liquidity adds).
///      `cumPrice` at a write equals the previous `cumPrice + previous.price * dt`.
///      Between observations the price used by consumers is this forward price of the
///      observation at or before `t`; beyond the last observation the last price is held.
contract SpotPool is Ownable {
    uint256 public constant RING_SIZE = 8192;
    uint256 public constant FEE_NUM = 997;
    uint256 public constant FEE_DEN = 1000;
    uint256 internal constant _PRICE_SCALE = 1e30; // 1e18 * 10^(18-6)

    /// @dev One TWAP sample. Packed into two storage slots.
    struct Observation {
        uint32 ts;
        uint224 cumPrice;
        uint192 price;
    }

    /// @notice 18-decimal MOCK base asset.
    address public immutable baseToken;
    /// @notice 6-decimal quote (tUSDC).
    address public immutable quoteToken;

    /// @notice Raw base-token units (18 decimals).
    uint256 public baseReserve;
    /// @notice Raw quote-token units (6 decimals).
    uint256 public quoteReserve;

    /// @notice Total observations ever written (does not cap at RING_SIZE).
    uint256 public observationCount;
    /// @notice Physical index of the next write (0..8191).
    uint16 public nextObsIndex;
    /// @notice Physical index of the newest observation. Meaningful iff `observationCount > 0`.
    uint16 public lastObsIndex;

    /// @notice Physical ring. Prefer `observationAt` for logical (oldest-first) access.
    Observation[8192] public observations;

    error ZeroAddress();
    error InvalidToken();
    error IdenticalTokens();
    error ZeroAmount();
    error EmptyReserves();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error PriceOverflow();
    error ObservationIndexOOB();

    event LiquidityAdded(uint256 baseAmt, uint256 quoteAmt);
    event Swap(address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, address to);
    event Sync(uint256 baseReserve, uint256 quoteReserve);
    event ObservationWritten(uint32 ts, uint224 cumPrice, uint192 price, uint16 index);

    /// @param base 18-decimal base token.
    /// @param quote 6-decimal quote token (tUSDC).
    /// @param owner_ Account that may `addLiquidity`.
    constructor(address base, address quote, address owner_) {
        if (base == address(0) || quote == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (base == quote) revert IdenticalTokens();
        baseToken = base;
        quoteToken = quote;
        _initializeOwner(owner_);
    }

    /// @notice Owner-only: pull `baseAmt`/`quoteAmt` from the caller and add them to reserves.
    /// @dev No fee. Either side may be zero (unbalanced add) so the demo owner can seed an
    ///      exact price; both zero reverts. Always writes an observation when the pool is
    ///      (or becomes) priced: `_writeObservation` runs *before* reserve changes so the
    ///      pre-change price is what TWAP accumulates up to this timestamp, then the last
    ///      observation's forward `price` is set to the post-change spot. A first seed
    ///      writes the new price after reserves are set. Same-timestamp adds update in
    ///      place and do not advance the ring.
    function addLiquidity(uint256 baseAmt, uint256 quoteAmt) external onlyOwner {
        if (baseAmt == 0 && quoteAmt == 0) revert ZeroAmount();

        bool priced = baseReserve != 0 && quoteReserve != 0;
        if (priced) {
            // Record the pre-change price at this timestamp (new slot or in-place).
            _writeObservation();
        }

        baseReserve += baseAmt;
        quoteReserve += quoteAmt;
        emit LiquidityAdded(baseAmt, quoteAmt);
        emit Sync(baseReserve, quoteReserve);

        if (baseReserve != 0 && quoteReserve != 0) {
            if (!priced) {
                // Empty → priced: first observation is the new spot.
                _writeObservation();
            } else {
                // Forward price becomes the post-change spot; cum already used the old price.
                _setLastPrice(priceWad());
            }
        }

        if (baseAmt != 0) {
            SafeTransferLib.safeTransferFrom(baseToken, msg.sender, address(this), baseAmt);
        }
        if (quoteAmt != 0) {
            SafeTransferLib.safeTransferFrom(quoteToken, msg.sender, address(this), quoteAmt);
        }
    }

    /// @notice Swap `amountIn` of `tokenIn` for the other token, sending output to `to`.
    /// @dev Writes an observation of the pre-swap spot (new slot on a new timestamp;
    ///      in-place `price` update if this timestamp already has an observation), then
    ///      sets the last observation's forward `price` to the post-swap spot.
    ///      Fee 0.30% on input, accrued in reserves.
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 out)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        address base = baseToken;
        address quote = quoteToken;
        if (tokenIn != base && tokenIn != quote) revert InvalidToken();

        uint256 reserveIn;
        uint256 reserveOut;
        bool baseIn = tokenIn == base;
        if (baseIn) {
            reserveIn = baseReserve;
            reserveOut = quoteReserve;
        } else {
            reserveIn = quoteReserve;
            reserveOut = baseReserve;
        }
        if (reserveIn == 0 || reserveOut == 0) revert EmptyReserves();

        _writeObservation();

        out = _getAmountOut(amountIn, reserveIn, reserveOut);
        if (out < minOut) revert InsufficientOutput(out, minOut);

        if (baseIn) {
            baseReserve = reserveIn + amountIn;
            quoteReserve = reserveOut - out;
        } else {
            quoteReserve = reserveIn + amountIn;
            baseReserve = reserveOut - out;
        }

        _setLastPrice(priceWad());
        emit Swap(msg.sender, tokenIn, amountIn, out, to);
        emit Sync(baseReserve, quoteReserve);

        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(baseIn ? quote : base, to, out);
    }

    /// @notice USD per 1 whole base token, 1e18-scaled.
    /// @dev `quoteReserve * 1e18 * 10^(18-6) / baseReserve` = `quoteReserve * 1e30 / baseReserve`.
    ///      Reverts `EmptyReserves` if either reserve is zero.
    function priceWad() public view returns (uint256) {
        uint256 base_ = baseReserve;
        uint256 quote_ = quoteReserve;
        if (base_ == 0 || quote_ == 0) revert EmptyReserves();
        return FixedPointMathLib.fullMulDiv(quote_, _PRICE_SCALE, base_);
    }

    /// @notice Anyone: write an observation of the current spot at `block.timestamp`.
    /// @dev If this timestamp already has an observation, only `price` is refreshed.
    ///      Otherwise a new ring slot is appended.
    function checkpoint() external {
        _writeObservation();
    }

    /// @notice Number of observations currently in the ring (`min(observationCount, 8192)`).
    function observationLength() public view returns (uint256) {
        uint256 n = observationCount;
        return n < RING_SIZE ? n : RING_SIZE;
    }

    /// @notice Observation at logical index `i` (0 = oldest, `observationLength()-1` = newest).
    function observationAt(uint256 i) public view returns (uint32 ts, uint224 cumPrice, uint192 price) {
        Observation storage obs = observations[_physical(i)];
        return (obs.ts, obs.cumPrice, obs.price);
    }

    /// @notice Newest observation. All zeros if the ring is empty.
    function latestObservation() public view returns (uint32 ts, uint224 cumPrice, uint192 price) {
        if (observationCount == 0) return (0, 0, 0);
        Observation storage obs = observations[lastObsIndex];
        return (obs.ts, obs.cumPrice, obs.price);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        INTERNALS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        // Uniswap V2: out = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
        uint256 ainFee = amountIn * FEE_NUM;
        uint256 denom = reserveIn * FEE_DEN + ainFee;
        return FixedPointMathLib.fullMulDiv(ainFee, reserveOut, denom);
    }

    function _alreadyWroteThisTimestamp() internal view returns (bool) {
        return observationCount != 0 && observations[lastObsIndex].ts == uint32(block.timestamp);
    }

    /// @dev Record current spot at `block.timestamp`. Same-timestamp calls update `price`
    ///      in place and do not advance the ring. Reverts if the pool is empty.
    function _writeObservation() internal {
        if (baseReserve == 0 || quoteReserve == 0) revert EmptyReserves();
        uint256 p = priceWad();
        if (_alreadyWroteThisTimestamp()) {
            _setLastPrice(p);
            return;
        }
        _pushObservation(p);
    }

    function _pushObservation(uint256 priceWad_) internal {
        if (priceWad_ > type(uint192).max) revert PriceOverflow();
        uint192 p = uint192(priceWad_);
        uint32 ts = uint32(block.timestamp);
        uint224 cum;
        uint256 n = observationCount;
        if (n != 0) {
            Observation storage prev = observations[lastObsIndex];
            uint256 dt = uint256(ts) - uint256(prev.ts); // revert if time went backwards
            // Wrap of uint224 is intended: consumers difference nearby samples only.
            unchecked {
                cum = prev.cumPrice + uint224(uint256(prev.price) * dt);
            }
        }
        uint16 idx = nextObsIndex;
        observations[idx] = Observation({ts: ts, cumPrice: cum, price: p});
        lastObsIndex = idx;
        // RING_SIZE is 8192 = 2^13; mask keeps the physical index in 0..8191 (fits uint16).
        nextObsIndex = uint16((uint256(idx) + 1) & (RING_SIZE - 1));
        unchecked {
            observationCount = n + 1;
        }
        emit ObservationWritten(ts, cum, p, idx);
    }

    function _setLastPrice(uint256 priceWad_) internal {
        if (observationCount == 0) return;
        if (priceWad_ > type(uint192).max) revert PriceOverflow();
        observations[lastObsIndex].price = uint192(priceWad_);
    }

    function _physical(uint256 logicalIndex) internal view returns (uint256) {
        uint256 n = observationCount;
        uint256 len = n < RING_SIZE ? n : RING_SIZE;
        if (logicalIndex >= len) revert ObservationIndexOOB();
        uint256 start = n < RING_SIZE ? 0 : uint256(nextObsIndex);
        uint256 phys = start + logicalIndex;
        if (phys >= RING_SIZE) phys -= RING_SIZE;
        return phys;
    }
}
