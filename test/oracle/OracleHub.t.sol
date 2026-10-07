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
        hub.registerAsset(ASSET, address(pool));

        base.mint(address(this), 50_000_000e18);
        usdc.mint(address(this), 50_000_000e6);
        base.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);

        // Deep seeded demo pool at $1.00.
        pool.addLiquidity(1_000_000e18, 1_000_000e6);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         HUB SURFACE                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_registerAsset_ownerOnly() public {
        assertTrue(hub.assetExists(ASSET));
        assertEq(hub.poolOf(ASSET), address(pool));
        vm.prank(address(0xB0B));
        vm.expectRevert(Ownable.Unauthorized.selector);
        hub.registerAsset(ASSET, address(pool));

        vm.expectRevert(OracleHub.ZeroAddress.selector);
        hub.registerAsset(ASSET, address(0));
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
        vm.expectRevert(
            abi.encodeWithSelector(IPriceOracle.HistoryUnavailable.selector, ASSET, uint64(T0))
        );
        hub.latestPrice(ASSET);

        pool.checkpoint();
        (uint256 p, uint64 ts) = hub.latestPrice(ASSET);
        assertEq(p, 1e18);
        assertEq(ts, T0);

        // Uncheckpointed liquidity add must NOT change latestPrice (obs is the source).
        pool.addLiquidity(0, 1_000_000e6); // spot now $2
        (p, ts) = hub.latestPrice(ASSET);
        assertEq(p, 1e18);
        assertEq(ts, T0);
        assertEq(pool.priceWad(), 2e18);
    }

    function test_checkpoint_asset() public {
        hub.checkpoint(ASSET);
        assertEq(pool.observationCount(), 1);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    TWAP HAND-COMPUTED                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Piecewise path: $1 for 300s, $2 for 300s, $1 thereafter.
    ///
    ///         t:  T0 ----+300----+600---->+
    ///         p:  $1     $2      $1
    ///         cum(T0)=0
    ///         cum(T0+300)=1e18*300
    ///         cum(T0+600)=300e18 + 2e18*300 = 900e18
    function test_twap_handComputedPiecewise() public {
        _checkpointRecord(); // T0, $1
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

        // 1-second window ending exactly on the $2 observation: still $1 (open at left)
        assertEq(hub.twapAt(ASSET, uint64(T0 + 300), 1), 1e18);

        // 1-second window just after the $2 observation: $2
        assertEq(hub.twapAt(ASSET, uint64(T0 + 301), 1), 2e18);

        // t-window == first observation timestamp (edge)
        assertEq(hub.twapAt(ASSET, uint64(T0 + 300), 300), 1e18);

        // t exactly on last observation
        assertEq(hub.twapAt(ASSET, uint64(T0 + 600), 600), 1.5e18);
    }

    function test_twap_futureExtrapolation() public {
        _checkpointRecord(); // T0 $1
        _warpSet(T0 + 100, 2e18);
        _checkpointRecord();

        // (T0+100, T0+400] is 300s of last price $2
        assertEq(hub.twapAt(ASSET, uint64(T0 + 400), 300), 2e18);
        // (T0, T0+400] = 100s@$1 + 300s@$2 = 1.75
        assertEq(hub.twapAt(ASSET, uint64(T0 + 400), 400), 1.75e18);
        assertEq(hub.twapAt(ASSET, uint64(T0 + 400), 400), _refTwap(T0 + 400, 400));
    }

    function test_twap_pastAndGaps() public {
        _checkpointRecord(); // T0 $1
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
        _checkpointRecord(); // T0 $1
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

    function test_twap_windowZeroAndHistoryUnavailable() public {
        _checkpointRecord();
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
        _checkpointRecord();
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
        _checkpointRecord(); // T0 $1, logical 0
        // Write 1024 additional observations, overwriting index 0 on the last one.
        for (uint256 i = 1; i <= 1024; ++i) {
            vm.warp(T0 + i);
            pool.checkpoint();
        }
        assertEq(pool.observationCount(), 1025);
        assertEq(pool.observationLength(), 1024);
        (uint32 oldest,,) = pool.observationAt(0);
        assertEq(oldest, T0 + 1);

        // History at T0 is gone.
        vm.expectRevert(
            abi.encodeWithSelector(IPriceOracle.HistoryUnavailable.selector, ASSET, uint64(T0 + 10))
        );
        hub.twapAt(ASSET, uint64(T0 + 10), 10);

        // Window fully inside the retained ring still works (constant $1).
        uint256 t = T0 + 1024;
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
        pool.checkpoint();
        // Need history back to now - lookback - step.
        vm.warp(T0 + lookback + step);
        pool.checkpoint();
        assertEq(hub.realizedVol(ASSET, lookback, step), 0);
    }

    function test_realizedVol_insufficientHistoryIsZero() public {
        pool.checkpoint();
        assertEq(hub.realizedVol(ASSET, 10, 0), 0);
        assertEq(hub.realizedVol(ASSET, 10, 60), 0); // lookback < 2*step
        assertEq(hub.realizedVol(ASSET, 600, 60), 0); // not enough elapsed time
    }

    function test_realizedVol_alternatingPath() public {
        uint32 step = 60;
        // 8 steps of alternating $1 / $2 after an initial $1 sample.
        pool.checkpoint();
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
        if (path.length != 0) return;
        _checkpointRecord();
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
