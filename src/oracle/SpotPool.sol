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
///      Quote token is tUSDC (6 decimals). Base token is an 18-decimal MOCK asset.
///      `priceWad` = USD per 1 whole base token, 1e18-scaled:
///          priceWad = quoteReserve * 10^30 / baseReserve
///
///      Swap fee is 0.30% (30 bps, Uniswap V2-style 997/1000) taken on input and accrued
///      in reserves (k = baseReserve * quoteReserve on raw token units is non-decreasing).
///      Liquidity adds do not charge a fee and do not write an observation. Either side
///      of `addLiquidity` may be zero so the demo owner can reprice without a swap.
///
///      Observations: a 1024-slot ring. A new slot is written on the first swap of a
///      (block, timestamp) pair — i.e. the first swap of each block, and also after
///      `vm.warp` within a block — and by `checkpoint()`. Later swaps at the same
///      block+timestamp only refresh the last slot's `price`. When the ring is full,
///      the next write overwrites the oldest sample (`nextObsIndex`); `observationCount`
///      keeps growing so consumers can detect wrap.
///
///      `cumPrice` is the cumulative `price * dt` in 1e18 scale. **Unchecked wrap of
///      `cumPrice` at 2^224 is intended** — consumers MUST difference nearby observations
///      with wrapping uint224 subtraction (the delta over any realistic window fits in
///      uint224). Interpolation uses wrapping add. `price` is stored as uint192; realistic
///      wad prices fit with huge margin (uint192 max ≈ 6.27e57). uint32 `ts` truncates
///      `block.timestamp` (Y2106); a backwards time jump reverts on `dt` subtraction.
///
///      Each observation's `price` is forward-looking: it is the spot after the write
///      (and after any later same-block/same-timestamp swaps). `cumPrice` at a write
///      equals the previous `cumPrice + previous.price * dt`.
contract SpotPool is Ownable {
    uint256 public constant RING_SIZE = 1024;
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
    /// @notice Physical index of the next write (0..1023).
    uint16 public nextObsIndex;
    /// @notice Physical index of the newest observation. Meaningful iff `observationCount > 0`.
    uint16 public lastObsIndex;
    /// @notice Block number of the last observation write.
    uint256 public lastObsBlockNumber;

    /// @notice Physical ring. Prefer `observationAt` for logical (oldest-first) access.
    Observation[1024] public observations;

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
    /// @dev No fee, no observation write. Either side may be zero (unbalanced add) so the
    ///      demo owner can seed an exact price; both zero reverts. Checkpoint afterwards
    ///      if the TWAP should pick up a reserve-ratio change from a liquidity add.
    function addLiquidity(uint256 baseAmt, uint256 quoteAmt) external onlyOwner {
        if (baseAmt == 0 && quoteAmt == 0) revert ZeroAmount();
        baseReserve += baseAmt;
        quoteReserve += quoteAmt;
        emit LiquidityAdded(baseAmt, quoteAmt);
        emit Sync(baseReserve, quoteReserve);
        if (baseAmt != 0) {
            SafeTransferLib.safeTransferFrom(baseToken, msg.sender, address(this), baseAmt);
        }
        if (quoteAmt != 0) {
            SafeTransferLib.safeTransferFrom(quoteToken, msg.sender, address(this), quoteAmt);
        }
    }

    /// @notice Swap `amountIn` of `tokenIn` for the other token, sending output to `to`.
    /// @dev First swap of a (block, timestamp) pair writes an observation. Subsequent
    ///      swaps at the same block+timestamp only refresh the last observation's `price`.
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

        _writeObservationIfNewSlot();

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
    function priceWad() public view returns (uint256) {
        uint256 base_ = baseReserve;
        if (base_ == 0) revert EmptyReserves();
        return FixedPointMathLib.fullMulDiv(quoteReserve, _PRICE_SCALE, base_);
    }

    /// @notice Anyone: write an observation of the current spot at `block.timestamp`.
    /// @dev If this (block, timestamp) already has an observation, only `price` is
    ///      refreshed. Otherwise a new ring slot is appended.
    function checkpoint() external {
        if (baseReserve == 0 || quoteReserve == 0) revert EmptyReserves();
        if (_alreadyWroteThisSlot()) {
            _setLastPrice(priceWad());
            return;
        }
        _pushObservation(priceWad());
    }

    /// @notice Number of observations currently in the ring (`min(observationCount, 1024)`).
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

    function _alreadyWroteThisSlot() internal view returns (bool) {
        return observationCount != 0 && lastObsBlockNumber == block.number
            && observations[lastObsIndex].ts == uint32(block.timestamp);
    }

    function _writeObservationIfNewSlot() internal {
        if (_alreadyWroteThisSlot()) return;
        _pushObservation(priceWad());
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
        nextObsIndex = uint16((uint256(idx) + 1) & (RING_SIZE - 1));
        unchecked {
            observationCount = n + 1;
        }
        lastObsBlockNumber = block.number;
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
