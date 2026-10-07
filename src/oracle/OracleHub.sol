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
///
///      `twapAt` is the time-weighted average of the piecewise-constant forward price over
///      `(t - window, t]`. Cumulatives are interpolated (or extrapolated past the last
///      observation using that observation's price). `cumPrice` wrapping is handled by
///      unchecked uint224 subtraction.
///
///      `realizedVol` is the sample standard deviation of log returns of `step`-second
///      TWAPs, annualised with `stdev * sqrt(31536000 / step)` (wad-scaled sqrt). Returns
///      0 if fewer than 3 price samples can be formed.
contract OracleHub is Ownable, IPriceOracle {
    uint256 internal constant _SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant _MAX_VOL_SAMPLES = 512;

    /// @notice Registered `assetId => SpotPool`.
    mapping(bytes32 => address) public pools;

    error ZeroAddress();
    error InvalidWindow();

    event AssetRegistered(bytes32 indexed assetId, address indexed pool);

    /// @param owner_ Account that may `registerAsset`.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
    }

    /// @notice Owner-only: bind `assetId` to a `SpotPool`.
    function registerAsset(bytes32 assetId, address pool) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        pools[assetId] = pool;
        emit AssetRegistered(assetId, pool);
    }

    /// @notice Pool registered for `assetId`, or `address(0)` if none.
    function poolOf(bytes32 assetId) external view returns (address) {
        return pools[assetId];
    }

    /// @inheritdoc IPriceOracle
    function assetExists(bytes32 assetId) external view returns (bool) {
        return pools[assetId] != address(0);
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
        if (n > _MAX_VOL_SAMPLES) n = _MAX_VOL_SAMPLES;
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

    /// @dev Cumulative price at time `t`, interpolating / extrapolating with the
    ///      observation at-or-before `t`'s forward price.
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
