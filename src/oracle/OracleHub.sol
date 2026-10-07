// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {SpotPool} from "./SpotPool.sol";

/// @title OracleHub
/// @notice MOCK/DEMO `IPriceOracle` over registered `SpotPool` TWAP rings.
/// @dev HONESTY: pool-TWAP oracles are manipulable at low liquidity. This hub reads demo
///      pools that are expected to be deeply seeded; it is NOT manipulation-resistant.
///      An attacker who moves the pool in the last seconds of an idle window influences
///      the TWAP (the last observation's forward price is held / extrapolated). Mitigated
///      only by depth + window, never eliminated.
///
///      `twapAt(assetId, t, window)` is the time-weighted average of the piecewise-constant
///      forward price over the half-open interval `(t - window, t]`:
///
///        Let `obs(τ)` be the latest observation with `ts <= τ` (at-or-before `τ`).
///        The price used at time `τ` is `obs(τ).price`. Beyond the last observation the
///        last price is held (extrapolated). Between observations the price is that of
///        the observation at or before `τ` — never interpolated between two prices.
///
///        Cumulative `C(τ) = obs(τ).cumPrice + obs(τ).price * (τ - obs(τ).ts)`
///        (uint224 wrap on `cumPrice` is intended; differences use wrapping subtraction).
///        `twap = (C(t) - C(t - window)) / window`.
///
///      Endpoint consequences (integer seconds):
///        - Instant `t - window` is excluded; instant `t` is included.
///        - A 1-second window ending exactly on an observation timestamp uses the
///          *previous* observation's price (the new forward price has `dt = 0` at its
///          own `ts`, so it does not contribute until the following second).
///        - A 1-second window starting at an observation timestamp uses that
///          observation's forward price.
///        - If `t - window` equals the oldest retained observation's timestamp, history
///          is available (`C(oldest)` is well-defined and the left endpoint is excluded).
///        - If `t - window` is strictly before the oldest observation, revert
///          `HistoryUnavailable`.
///
///      `realizedVol` is the sample standard deviation of log returns of `step`-second
///      TWAPs, annualised with `stdev * sqrt(31536000 / step)` (wad-scaled sqrt). Returns
///      0 if fewer than 3 price samples can be formed. Sample count is capped at 512.
contract OracleHub is Ownable, IPriceOracle {
    uint256 internal constant _SECONDS_PER_YEAR = 31_536_000;
    /// @notice Cap on TWAP samples used by `realizedVol` (lookback/step + 1).
    uint256 public constant MAX_VOL_SAMPLES = 512;

    /// @notice Registered `assetId => SpotPool`.
    mapping(bytes32 => address) public pools;
    /// @notice Owner-set minimum quote reserve (raw 6-decimal units) for `isHealthy`.
    mapping(bytes32 => uint256) public minQuoteReserve;

    error ZeroAddress();
    error InvalidWindow();
    error AssetAlreadyRegistered(bytes32 assetId);

    event AssetRegistered(bytes32 indexed assetId, address indexed pool, uint256 minQuoteReserve);

    /// @param owner_ Account that may `registerAsset`.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
    }

    /// @notice Owner-only, one-time: bind `assetId` to a `SpotPool` and its health floor.
    /// @param assetId Asset key (e.g. `keccak256("MON")`).
    /// @param pool SpotPool whose quote token is tUSDC (6 decimals).
    /// @param minQuoteReserve_ Minimum `quoteReserve` for `isHealthy` to return true.
    function registerAsset(bytes32 assetId, address pool, uint256 minQuoteReserve_) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        if (pools[assetId] != address(0)) revert AssetAlreadyRegistered(assetId);
        pools[assetId] = pool;
        minQuoteReserve[assetId] = minQuoteReserve_;
        emit AssetRegistered(assetId, pool, minQuoteReserve_);
    }

    /// @notice Pool registered for `assetId`, or `address(0)` if none.
    function poolOf(bytes32 assetId) external view returns (address) {
        return pools[assetId];
    }

    /// @inheritdoc IPriceOracle
    function assetExists(bytes32 assetId) external view returns (bool) {
        return pools[assetId] != address(0);
    }

    /// @notice Whether the registered pool's quote reserve meets `minQuoteReserve[assetId]`.
    /// @dev Reverts `UnknownAsset` if `assetId` was never registered.
    function isHealthy(bytes32 assetId) external view returns (bool) {
        address pool = pools[assetId];
        if (pool == address(0)) revert UnknownAsset(assetId);
        return SpotPool(pool).quoteReserve() >= minQuoteReserve[assetId];
    }

    /// @notice Anyone: write a `SpotPool` observation for `assetId` at `block.timestamp`.
    function checkpoint(bytes32 assetId) external {
        address pool = pools[assetId];
        if (pool == address(0)) revert UnknownAsset(assetId);
        SpotPool(pool).checkpoint();
    }

    /// @inheritdoc IPriceOracle
    function latestPrice(bytes32 assetId) external view returns (uint256 priceWad, uint64 updatedAt) {
        SpotPool pool = _pool(assetId);
        if (pool.observationCount() == 0) revert HistoryUnavailable(assetId, uint64(block.timestamp));
        (uint32 ts,, uint192 price) = pool.latestObservation();
        return (uint256(price), ts);
    }

    /// @inheritdoc IPriceOracle
    /// @dev See contract-level NatSpec for exact `(t - window, t]` accumulation.
    function twapAt(bytes32 assetId, uint64 t, uint32 window) external view returns (uint256 priceWad) {
        return _twapAt(assetId, t, window);
    }

    /// @inheritdoc IPriceOracle
    function realizedVol(bytes32 assetId, uint32 lookback, uint32 step) external view returns (uint256 volWad) {
        if (step == 0) return 0;
        // Need ≥ 3 price samples: t, t-step, t-2*step  ⇒ lookback >= 2*step.
        if (uint256(lookback) < 2 * uint256(step)) return 0;
        if (pools[assetId] == address(0)) revert UnknownAsset(assetId);

        uint256 n = uint256(lookback) / uint256(step) + 1;
        if (n > MAX_VOL_SAMPLES) n = MAX_VOL_SAMPLES;
        if (n < 3) return 0;
        if (!_hasVolHistory(assetId, n, step)) return 0;

        (int256[] memory rets, uint256 nRets) = _logReturns(assetId, n, step);
        if (nRets < 2) return 0; // < 3 prices

        uint256 stdev = _sampleStdev(rets, nRets);
        // wad-scaled sqrt so `stdev * sqrt(YEAR/step)` keeps sub-integer resolution.
        uint256 annWad = FixedPointMathLib.sqrt((_SECONDS_PER_YEAR * 1e18) / uint256(step));
        return stdev * annWad / 1e9;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        INTERNALS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _hasVolHistory(bytes32 assetId, uint256 n, uint32 step) internal view returns (bool) {
        uint256 tNow = block.timestamp;
        uint256 span = n * uint256(step);
        if (tNow < span) return false;
        SpotPool pool = SpotPool(pools[assetId]);
        if (pool.observationLength() == 0) return false;
        (uint32 firstTs,,) = pool.observationAt(0);
        uint64 oldestT = uint64(tNow - (n - 1) * uint256(step));
        if (uint256(oldestT) < uint256(step)) return false;
        return firstTs <= oldestT - step;
    }

    function _logReturns(bytes32 assetId, uint256 n, uint32 step)
        internal
        view
        returns (int256[] memory rets, uint256 nRets)
    {
        rets = new int256[](n - 1);
        uint256 prevP;
        uint256 tNow = block.timestamp;
        for (uint256 i = n; i > 0; --i) {
            uint256 p = _twapAt(assetId, uint64(tNow - (i - 1) * uint256(step)), step);
            if (p == 0) return (rets, 0);
            if (prevP != 0) {
                rets[nRets] =
                    FixedPointMathLib.lnWad(int256(p)) - FixedPointMathLib.lnWad(int256(prevP));
                unchecked {
                    ++nRets;
                }
            }
            prevP = p;
        }
    }

    function _sampleStdev(int256[] memory rets, uint256 nRets) internal pure returns (uint256) {
        int256 sum;
        for (uint256 i; i < nRets; ++i) {
            sum += rets[i];
        }
        int256 mean = sum / int256(nRets);
        uint256 acc;
        for (uint256 i; i < nRets; ++i) {
            int256 d = rets[i] - mean;
            uint256 ad = uint256(d >= 0 ? d : -d);
            acc += ad * ad;
        }
        return FixedPointMathLib.sqrt(acc / (nRets - 1));
    }

    function _pool(bytes32 assetId) internal view returns (SpotPool pool) {
        address p = pools[assetId];
        if (p == address(0)) revert UnknownAsset(assetId);
        pool = SpotPool(p);
    }

    function _twapAt(bytes32 assetId, uint64 t, uint32 window) internal view returns (uint256) {
        if (window == 0) revert InvalidWindow();
        if (t < window) revert HistoryUnavailable(assetId, t);
        SpotPool pool = _pool(assetId);
        if (pool.observationLength() == 0) revert HistoryUnavailable(assetId, t);
        (uint32 firstTs,,) = pool.observationAt(0);
        uint64 t0 = t - window;
        // Revert with the queried `t` (not t-window) so callers can match on the argument they passed.
        if (t0 < firstTs) revert HistoryUnavailable(assetId, t);
        uint224 c1 = _cumAt(assetId, t);
        uint224 c0 = _cumAt(assetId, t0);
        uint256 twap;
        unchecked {
            // uint224 wrap of cumPrice is intended.
            twap = uint256(uint224(c1 - c0)) / uint256(window);
        }
        return twap;
    }

    /// @dev Cumulative price at time `t`. Uses the observation at-or-before `t`'s forward
    ///      price for every second after that observation, including extrapolation past
    ///      the last observation. `C(t) - C(t - window)` therefore integrates the
    ///      piecewise-constant at-or-before price over `(t - window, t]`.
    function _cumAt(bytes32 assetId, uint64 t) internal view returns (uint224) {
        SpotPool pool = _pool(assetId);
        uint256 len = pool.observationLength();
        if (len == 0) revert HistoryUnavailable(assetId, t);

        (uint32 firstTs,,) = pool.observationAt(0);
        if (t < firstTs) revert HistoryUnavailable(assetId, t);

        uint256 idx = _indexAtOrBefore(pool, t, len);
        (uint32 ts, uint224 cum, uint192 price) = pool.observationAt(idx);
        uint256 dt = uint256(t) - uint256(ts);
        unchecked {
            return uint224(uint256(cum) + uint256(price) * dt);
        }
    }

    /// @dev Rightmost logical index with `ts <= t`. Caller guarantees `t >= first.ts`.
    function _indexAtOrBefore(SpotPool pool, uint64 t, uint256 len) internal view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = len; // exclusive
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            (uint32 ts,,) = pool.observationAt(mid);
            if (ts <= t) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // `lo` is the first index with ts > t (or `len`). Predecessor has ts <= t.
        return lo - 1;
    }
}
