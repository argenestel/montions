// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {TestUSDC} from "../../src/mocks/TestUSDC.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {SpotPool} from "../../src/oracle/SpotPool.sol";
import {OracleHub} from "../../src/oracle/OracleHub.sol";

/// @dev Piecewise-constant forward price sample recorded independently of the pool ring.
struct Pt {
    uint32 ts;
    uint256 price;
}

contract OracleHubTest is Test {
    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant YEAR = 31_536_000;
    bytes32 internal constant ASSET = keccak256("MON");
    bytes32 internal constant UNKNOWN = keccak256("NOPE");

    TestUSDC internal usdc;
    MockERC20 internal base;
    SpotPool internal pool;
    OracleHub internal hub;

    Pt[] internal path;

    function setUp() public {
        vm.warp(T0);
        usdc = new TestUSDC(address(this));
        base = new MockERC20("Test MON", "tMON", 18, address(this));
        pool = new SpotPool(address(base), address(usdc), address(this));
        hub = new OracleHub(address(this));
        hub.registerAsset(ASSET, address(pool), 0);

        base.mint(address(this), 50_000_000e18);
        usdc.mint(address(this), 50_000_000e6);
        base.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);

        // Deep seeded demo pool at $1.00. addLiquidity writes the first observation.
        pool.addLiquidity(1_000_000e18, 1_000_000e6);
        _syncPath();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         HUB SURFACE                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_registerAsset_ownerOnly() public {
        assertTrue(hub.assetExists(ASSET));
        assertEq(hub.poolOf(ASSET), address(pool));
        bytes32 other = keccak256("NVDA");
        vm.prank(address(0xB0B));
        vm.expectRevert(Ownable.Unauthorized.selector);
        hub.registerAsset(other, address(pool), 0);

        vm.expectRevert(OracleHub.ZeroAddress.selector);
        hub.registerAsset(other, address(0), 0);

        hub.registerAsset(other, address(pool), 123);
        assertEq(hub.poolOf(other), address(pool));
        assertEq(hub.minQuoteReserve(other), 123);
    }

    function test_registerAsset_oneTimeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(OracleHub.AssetAlreadyRegistered.selector, ASSET));
        hub.registerAsset(ASSET, address(pool), 1);

        bytes32 other = keccak256("X");
        hub.registerAsset(other, address(pool), 50_000e6);
        vm.expectRevert(abi.encodeWithSelector(OracleHub.AssetAlreadyRegistered.selector, other));
        hub.registerAsset(other, address(pool), 0);
    }

    function test_isHealthy_trueFalseUnknown() public {
        // ASSET was registered with minQuoteReserve = 0, so any quote reserve is healthy.
        assertTrue(hub.isHealthy(ASSET));

        bytes32 guarded = keccak256("GUARDED");
        SpotPool p2 = new SpotPool(address(base), address(usdc), address(this));
        hub.registerAsset(guarded, address(p2), 100_000e6);

        assertFalse(hub.isHealthy(guarded), "empty pool below floor");

        base.approve(address(p2), type(uint256).max);
        usdc.approve(address(p2), type(uint256).max);
        p2.addLiquidity(1_000e18, 50_000e6);
        assertFalse(hub.isHealthy(guarded), "50k < 100k floor");

        p2.addLiquidity(1_000e18, 50_000e6);
        assertTrue(hub.isHealthy(guarded), "100k >= 100k floor");

        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.UnknownAsset.selector, UNKNOWN));
        hub.isHealthy(UNKNOWN);
    }

    function test_unknownAsset() public {
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.UnknownAsset.selector, UNKNOWN));
        hub.latestPrice(UNKNOWN);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.UnknownAsset.selector, UNKNOWN));
        hub.twapAt(UNKNOWN, uint64(T0 + 10), 10);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.UnknownAsset.selector, UNKNOWN));
        hub.checkpoint(UNKNOWN);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.UnknownAsset.selector, UNKNOWN));
        hub.realizedVol(UNKNOWN, 3600, 60);
    }

    function test_latestPrice_fromObservation() public {
        (uint256 p, uint64 ts) = hub.latestPrice(ASSET);
        assertEq(p, 1e18);
        assertEq(ts, T0);

        // addLiquidity writes / updates the observation so latestPrice tracks the new spot.
        vm.warp(T0 + 10);
        pool.addLiquidity(0, 1_000_000e6); // spot now $2
        (p, ts) = hub.latestPrice(ASSET);
        assertEq(p, 2e18);
        assertEq(ts, T0 + 10);
        assertEq(pool.priceWad(), 2e18);
    }

    function test_checkpoint_asset() public {
        uint256 n = pool.observationCount();
        vm.warp(T0 + 1);
        hub.checkpoint(ASSET);
        assertEq(pool.observationCount(), n + 1);
    }

    function test_realizedVol_sampleCapIs512() public view {
        assertEq(hub.MAX_VOL_SAMPLES(), 512);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    TWAP HAND-COMPUTED                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Exact `(t - window, t]` accumulation, hand-computed.
    ///
    ///         Seed at T0 wrote obs0: ts=T0, cum=0, price=$1.
    ///         Then:
    ///           t = T0+300  obs1 price=$2  cum = $1 * 300 = 300e18
    ///           t = T0+600  obs2 price=$1  cum = 300e18 + $2 * 300 = 900e18
    ///
    ///         C(τ) = obs(τ).cum + obs(τ).price * (τ - obs(τ).ts)
    ///         twap(t, w) = (C(t) - C(t-w)) / w
    ///
    ///         C(T0)        = 0
    ///         C(T0+300)    = 300e18 + $2 * 0 = 300e18
    ///         C(T0+301)    = 300e18 + $2 * 1 = 302e18
    ///         C(T0+600)    = 900e18
    ///         C(T0+299)    = 0 + $1 * 299 = 299e18
    function test_twap_handComputedPiecewise() public {
        // setUp already seeded $1 at T0.
        _warpSet(T0 + 300, 2e18);
        _checkpointRecord();
        _warpSet(T0 + 600, 1e18);
        _checkpointRecord();

        // Full 600s: (300*$1 + 300*$2)/600 = $1.50
        assertEq(hub.twapAt(ASSET, uint64(T0 + 600), 600), 1.5e18);
        assertEq(_refTwap(T0 + 600, 600), 1.5e18);

        // Second half: all $2
        assertEq(hub.twapAt(ASSET, uint64(T0 + 600), 300), 2e18);

        // First half via interpolation at t=T0+300: all $1
        assertEq(hub.twapAt(ASSET, uint64(T0 + 300), 300), 1e18);

        // Window straddling the $1→$2 jump: (T0+150, T0+450] = 150s@$1 + 150s@$2 = $1.50
        assertEq(hub.twapAt(ASSET, uint64(T0 + 450), 300), 1.5e18);

        // 1-second window ending exactly on the $2 observation: still $1
        // (new forward price has dt=0 at its own ts).
        assertEq(hub.twapAt(ASSET, uint64(T0 + 300), 1), 1e18);
        // C(T0+300)-C(T0+299) = 300e18 - 299e18 = 1e18

        // 1-second window just after the $2 observation: $2
        assertEq(hub.twapAt(ASSET, uint64(T0 + 301), 1), 2e18);

        // t-window == first observation timestamp (left endpoint excluded, history available)
        assertEq(hub.twapAt(ASSET, uint64(T0 + 300), 300), 1e18);

        // t exactly on last observation
        assertEq(hub.twapAt(ASSET, uint64(T0 + 600), 600), 1.5e18);
    }

    /// @notice Closed-form integers proving `(t-window, t]` endpoints and last-price hold.
    ///
    ///         obs: t=T0     p=$1   cum=0           (seed)
    ///              t=T0+10  p=$10  cum=$1*10=10e18
    ///              t=T0+15  p=$20  cum=10e18+$10*5=60e18
    ///              t=T0+20  p=$40  cum=60e18+$20*5=160e18
    ///
    ///         C(τ)=obs(τ).cum + obs(τ).price*(τ-obs(τ).ts)
    ///         C(T0+10)=10e18, C(T0+15)=60e18, C(T0+20)=160e18, C(T0+30)=560e18
    ///
    ///         (T0, T0+10]      = $1
    ///         (T0+10, T0+15]   = $10
    ///         (T0+15, T0+20]   = $20
    ///         (T0+10, T0+20]   = (5*$10+5*$20)/10 = $15
    ///         (T0+19, T0+20]   = $20   (new price has dt=0 at its own ts)
    ///         (T0+20, T0+21]   = $40   (forward price starts the next second)
    ///         (T0+20, T0+30]   = $40   (extrapolate last price)
    ///         (T0, T0+30]      = (10*$1+5*$10+5*$20+10*$40)/30 = 560e18/30
    function test_twap_handComputedEndpointsAndExtrapolation() public {
        _warpSet(T0 + 10, 10e18);
        _checkpointRecord();
        _warpSet(T0 + 15, 20e18);
        _checkpointRecord();
        _warpSet(T0 + 20, 40e18);
        _checkpointRecord();

        assertEq(hub.twapAt(ASSET, uint64(T0 + 10), 10), 1e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 15), 5), 10e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 20), 5), 20e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 20), 10), 15e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 20), 1), 20e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 21), 1), 40e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 30), 10), 40e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 30), 30), uint256(560e18) / 30);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 30), 30), _refTwap(T0 + 30, 30));
    }

    function test_twap_futureExtrapolation() public {
        _warpSet(T0 + 100, 2e18);
        _checkpointRecord();

        // (T0+100, T0+400] is 300s of last price $2
        assertEq(hub.twapAt(ASSET, uint64(T0 + 400), 300), 2e18);
        // (T0, T0+400] = 100s@$1 + 300s@$2 = 1.75
        assertEq(hub.twapAt(ASSET, uint64(T0 + 400), 400), 1.75e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 400), 400), _refTwap(T0 + 400, 400));
    }

    function test_twap_pastAndGaps() public {
        vm.warp(T0 + 10_000);
        _setPrice(3e18);
        _checkpointRecord();

        // Gap of 10_000s at $1, then $3 going forward.
        assertEq(hub.twapAt(ASSET, uint64(T0 + 10_000), 10_000), 1e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 10_500), 500), 3e18);
        // Straddle: 200s@$1 + 300s@$3 = (200+900)/500 = 2.2
        assertEq(hub.twapAt(ASSET, uint64(T0 + 10_300), 500), 2.2e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 10_300), 500), _refTwap(T0 + 10_300, 500));
    }

    function test_twap_sameBlockSwaps() public {
        vm.warp(T0 + 100);

        uint256 n0 = pool.observationCount();
        pool.swapExactIn(address(usdc), 50_000e6, 0, address(this));
        pool.swapExactIn(address(usdc), 50_000e6, 0, address(this));
        assertEq(pool.observationCount(), n0 + 1, "one observation per timestamp");
        _syncPath();

        (uint32 ts,, uint192 p) = pool.latestObservation();
        assertEq(ts, T0 + 100);
        assertEq(uint256(p), pool.priceWad());

        // (T0, T0+100] still $1; new price has zero elapsed time at t=T0+100
        assertEq(hub.twapAt(ASSET, uint64(T0 + 100), 100), 1e18);
        vm.warp(T0 + 200);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 200), 100), pool.priceWad());
    }

    function test_twap_addLiquidityDoesNotRewriteHistory() public {
        // Owner one-sided add at T0+100 moves spot $1 → $2. TWAP over (T0, T0+100]
        // must still be $1 (pre-change price recorded before reserves move).
        vm.warp(T0 + 100);
        pool.addLiquidity(0, 1_000_000e6);
        _syncPath();
        assertEq(pool.priceWad(), 2e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 100), 100), 1e18);
        // After the add, last price $2 is what extrapolates.
        assertEq(hub.twapAt(ASSET, uint64(T0 + 200), 100), 2e18);
        // Combined (T0, T0+200] = 100s@$1 + 100s@$2 = $1.50
        assertEq(hub.twapAt(ASSET, uint64(T0 + 200), 200), 1.5e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 200), 200), _refTwap(T0 + 200, 200));
    }

    function test_twap_windowZeroAndHistoryUnavailable() public {
        vm.expectRevert(OracleHub.InvalidWindow.selector);
        hub.twapAt(ASSET, uint64(T0 + 10), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IPriceOracle.HistoryUnavailable.selector, ASSET, uint64(T0 + 10))
        );
        hub.twapAt(ASSET, uint64(T0 + 10), 11); // t-window < first ts

        vm.expectRevert(
            abi.encodeWithSelector(IPriceOracle.HistoryUnavailable.selector, ASSET, uint64(T0 - 1))
        );
        hub.twapAt(ASSET, uint64(T0 - 1), 1);
    }

    function test_twap_multipleSwapsRecordedPath() public {
        uint256 t = T0;
        for (uint256 i; i < 8; ++i) {
            t += 15 + i * 3;
            vm.warp(t);
            if (i % 2 == 0) {
                pool.swapExactIn(address(usdc), 1_000e6 + i * 100e6, 0, address(this));
            } else {
                pool.swapExactIn(address(base), 1_000e18 + i * 50e18, 0, address(this));
            }
            _syncPath();
        }
        uint256 last = path[path.length - 1].ts;
        uint256 first = path[0].ts;
        uint256 window = last - first;
        assertEq(hub.twapAt(ASSET, uint64(last), uint32(window)), _refTwap(last, window));
        assertEq(hub.twapAt(ASSET, uint64(last + 50), 40), _refTwap(last + 50, 40));
        uint256 mid = (first + last) / 2;
        uint256 w = mid - first;
        assertEq(hub.twapAt(ASSET, uint64(mid), uint32(w)), _refTwap(mid, w));
    }

    function test_twap_ringWraparound() public {
        // setUp wrote obs at T0. Write RING_SIZE more, overwriting index 0 on the last one.
        uint256 ring = pool.RING_SIZE();
        vm.pauseGasMetering();
        for (uint256 i = 1; i <= ring; ++i) {
            vm.warp(T0 + i);
            pool.checkpoint();
        }
        vm.resumeGasMetering();
        assertEq(pool.observationCount(), ring + 1);
        assertEq(pool.observationLength(), ring);
        (uint32 oldest,,) = pool.observationAt(0);
        assertEq(oldest, T0 + 1);

        // History at T0 is gone: window start predates the oldest observation.
        vm.expectRevert(
            abi.encodeWithSelector(IPriceOracle.HistoryUnavailable.selector, ASSET, uint64(T0 + 10))
        );
        hub.twapAt(ASSET, uint64(T0 + 10), 10);

        // Window fully inside the retained ring still works (constant $1).
        uint256 t = T0 + ring;
        assertEq(hub.twapAt(ASSET, uint64(t), 500), 1e18);
        // Left edge of retained history: t-window == oldest ts
        assertEq(hub.twapAt(ASSET, uint64(T0 + 1 + 50), 50), 1e18);

        // One second before oldest is unavailable.
        vm.expectRevert(
            abi.encodeWithSelector(
                IPriceOracle.HistoryUnavailable.selector, ASSET, uint64(T0 + 1 + 50)
            )
        );
        hub.twapAt(ASSET, uint64(T0 + 1 + 50), 51);
    }

    function test_fuzz_twapAtMatchesReference(uint64 tRaw, uint32 windowRaw) public {
        _buildFuzzPath();
        uint256 first = path[0].ts;
        uint256 last = path[path.length - 1].ts;
        uint256 t = bound(uint256(tRaw), first + 1, last + 5_000);
        uint256 maxW = t - first;
        uint256 window = bound(uint256(windowRaw), 1, maxW);

        uint256 got = hub.twapAt(ASSET, uint64(t), uint32(window));
        uint256 exp = _refTwap(t, window);
        assertEq(got, exp);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       REALIZED VOL                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_realizedVol_constantPriceIsZero() public {
        uint32 step = 60;
        uint32 lookback = 600; // 10 steps → 11 samples
        // Need history back to now - lookback - step. Seed already wrote T0.
        vm.warp(T0 + lookback + step);
        pool.checkpoint();
        assertEq(hub.realizedVol(ASSET, lookback, step), 0);
    }

    function test_realizedVol_insufficientHistoryIsZero() public view {
        assertEq(hub.realizedVol(ASSET, 10, 0), 0);
        assertEq(hub.realizedVol(ASSET, 10, 60), 0); // lookback < 2*step
        assertEq(hub.realizedVol(ASSET, 600, 60), 0); // not enough elapsed time
    }

    function test_realizedVol_alternatingPath() public {
        uint32 step = 60;
        // 8 steps of alternating $1 / $2 after an initial $1 sample (seed).
        bool high;
        for (uint256 i = 1; i <= 12; ++i) {
            vm.warp(T0 + i * uint256(step));
            high = !high;
            _setPrice(high ? 2e18 : 1e18);
            pool.checkpoint();
        }
        uint32 lookback = 8 * step; // 9 samples, 8 returns
        uint256 vol = hub.realizedVol(ASSET, lookback, step);
        assertGt(vol, 0);

        // Independent expected value from the same sample set the hub would read.
        uint256 n = uint256(lookback) / uint256(step) + 1;
        uint256[] memory prices = new uint256[](n);
        uint256 tNow = block.timestamp;
        for (uint256 i; i < n; ++i) {
            uint64 t = uint64(tNow - (n - 1 - i) * uint256(step));
            prices[i] = hub.twapAt(ASSET, t, step);
        }
        uint256 exp = _sampleVol(prices, step);
        assertEq(vol, exp);

        // Ballpark: |ln 2| * sqrt(YEAR/step) scaled by sample-stdev factor √(n/(n-1)).
        int256 ln2 = FixedPointMathLib.lnWad(2e18);
        uint256 a = uint256(ln2);
        uint256 nRets = n - 1;
        uint256 stdev = a * FixedPointMathLib.sqrt(nRets * 1e18 / (nRets - 1)) / 1e9;
        uint256 ann = stdev * FixedPointMathLib.sqrt((YEAR * 1e18) / uint256(step)) / 1e9;
        assertApproxEqRel(vol, ann, 0.02e18);
    }

    function test_realizedVol_capsAt512Samples() public {
        // Two observations spanning plenty of time: constant $1, vol = 0 even if lookback
        // would request more than 512 samples without the cap.
        vm.warp(T0 + 1_000_000);
        pool.checkpoint();
        uint32 step = 60;
        uint32 lookback = uint32(600 * 60); // 601 samples if uncapped
        assertGt(uint256(lookback) / uint256(step) + 1, 512);
        assertEq(hub.realizedVol(ASSET, lookback, step), 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         HELPERS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _checkpointRecord() internal {
        pool.checkpoint();
        _syncPath();
    }

    function _syncPath() internal {
        (uint32 ts,, uint192 price) = pool.latestObservation();
        if (path.length == 0 || path[path.length - 1].ts != ts) {
            path.push(Pt({ts: ts, price: uint256(price)}));
        } else {
            path[path.length - 1].price = uint256(price);
        }
    }

    function _warpSet(uint256 ts, uint256 priceWad) internal {
        vm.warp(ts);
        _setPrice(priceWad);
    }

    function _setPrice(uint256 priceWad) internal {
        uint256 b = pool.baseReserve();
        uint256 q = pool.quoteReserve();
        uint256 targetQ = FixedPointMathLib.fullMulDiv(priceWad, b, 1e30);
        if (targetQ > q) {
            usdc.mint(address(this), targetQ - q);
            pool.addLiquidity(0, targetQ - q);
        } else if (targetQ < q) {
            uint256 targetB = FixedPointMathLib.fullMulDiv(q, 1e30, priceWad);
            if (targetB > b) {
                base.mint(address(this), targetB - b);
                pool.addLiquidity(targetB - b, 0);
            }
        }
        assertEq(pool.priceWad(), priceWad, "exact price");
        _syncPath();
    }

    function _refCum(uint256 t) internal view returns (uint256 cum) {
        uint256 n = path.length;
        require(n > 0 && t >= path[0].ts, "ref hist");
        uint256 i;
        while (i + 1 < n && path[i + 1].ts <= t) {
            unchecked {
                ++i;
            }
        }
        for (uint256 j; j < i; ++j) {
            cum += path[j].price * (uint256(path[j + 1].ts) - uint256(path[j].ts));
        }
        cum += path[i].price * (t - path[i].ts);
    }

    function _refTwap(uint256 t, uint256 window) internal view returns (uint256) {
        return (_refCum(t) - _refCum(t - window)) / window;
    }

    function _buildFuzzPath() internal {
        if (path.length > 1) return;
        uint256 t = T0;
        uint256[12] memory prices = [
            uint256(1e18),
            1.2e18,
            0.8e18,
            2e18,
            2e18,
            1.5e18,
            1e18,
            3e18,
            0.5e18,
            0.5e18,
            1e18,
            1.1e18
        ];
        uint256[12] memory gaps = [uint256(1), 2, 5, 1, 30, 7, 4, 90, 3, 1, 11, 8];
        for (uint256 i; i < 12; ++i) {
            t += gaps[i];
            _warpSet(t, prices[i]);
            _checkpointRecord();
        }
    }

    function _sampleVol(uint256[] memory prices, uint32 step) internal pure returns (uint256) {
        uint256 nRets = prices.length - 1;
        int256 sum;
        int256[] memory rets = new int256[](nRets);
        for (uint256 i; i < nRets; ++i) {
            int256 r = FixedPointMathLib.lnWad(int256(prices[i + 1]))
                - FixedPointMathLib.lnWad(int256(prices[i]));
            rets[i] = r;
            sum += r;
        }
        int256 mean = sum / int256(nRets);
        uint256 acc;
        for (uint256 i; i < nRets; ++i) {
            int256 d = rets[i] - mean;
            uint256 ad = uint256(d >= 0 ? d : -d);
            acc += ad * ad;
        }
        uint256 stdev = FixedPointMathLib.sqrt(acc / (nRets - 1));
        uint256 annWad = FixedPointMathLib.sqrt((YEAR * 1e18) / uint256(step));
        return stdev * annWad / 1e9;
    }
}
