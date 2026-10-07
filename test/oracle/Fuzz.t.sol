// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OracleTestBase} from "./OracleTestBase.sol";
import {SpotPool} from "../../src/oracle/SpotPool.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

contract OracleFuzzTest is OracleTestBase {
    function setUp() public {
        _setUpOracle();
        _seedDeep();
        _fund(alice, 500_000e18, 500_000e6);
        pool.checkpoint();
    }

    function testFuzz_swapInvariants(uint256 amountIn, bool baseIn) public {
        amountIn = bound(amountIn, 1e15, 1_000e18);
        if (!baseIn) {
            // quote side is 6 decimals; map a wad-ish amount into quote units.
            amountIn = bound(amountIn / 1e12, 1e3, 1_000e6);
        }

        uint256 b0 = pool.baseReserve();
        uint256 q0 = pool.quoteReserve();
        uint256 k0 = b0 * q0;

        address tokenIn = baseIn ? address(base) : address(usdc);
        uint256 reserveIn = baseIn ? b0 : q0;
        uint256 reserveOut = baseIn ? q0 : b0;
        uint256 expected = _expectedOut(amountIn, reserveIn, reserveOut);
        vm.assume(expected > 0);

        uint256 balInBefore = baseIn ? base.balanceOf(alice) : usdc.balanceOf(alice);
        uint256 balOutBefore = baseIn ? usdc.balanceOf(alice) : base.balanceOf(alice);
        vm.assume(balInBefore >= amountIn);

        vm.prank(alice);
        uint256 out = pool.swapExactIn(tokenIn, amountIn, 0, alice);
        assertEq(out, expected);

        uint256 b1 = pool.baseReserve();
        uint256 q1 = pool.quoteReserve();
        assertGt(b1, 0);
        assertGt(q1, 0);
        if (b0 <= type(uint256).max / q0 && b1 <= type(uint256).max / q1) {
            assertGe(b1 * q1, k0);
        }
        if (baseIn) {
            assertEq(b1, b0 + amountIn);
            assertEq(q1, q0 - out);
            assertEq(base.balanceOf(alice), balInBefore - amountIn);
            assertEq(usdc.balanceOf(alice), balOutBefore + out);
        } else {
            assertEq(q1, q0 + amountIn);
            assertEq(b1, b0 - out);
            assertEq(usdc.balanceOf(alice), balInBefore - amountIn);
            assertEq(base.balanceOf(alice), balOutBefore + out);
        }
    }

    function testFuzz_twapAt(uint256 seed, uint32 window, uint32 extra) public {
        _walk(seed, 8);
        window = uint32(bound(window, 1, 200));
        extra = uint32(bound(extra, 0, 80));

        (uint32 firstTs,,) = pool.observationAt(0);
        (uint32 lastTs,,) = pool.latestObservation();
        uint64 t = uint64(uint256(lastTs) + extra);
        if (t < window) return;
        uint64 t0 = t - window;

        if (t0 < firstTs) {
            vm.expectRevert(abi.encodeWithSelector(IPriceOracle.HistoryUnavailable.selector, assetId, t));
            hub.twapAt(assetId, t, window);
            return;
        }

        uint256 got = hub.twapAt(assetId, t, window);
        uint256 ref = _refTwap(pool, t, window);
        assertEq(got, ref);
        // Sanity: TWAP lies between min and max recorded forward prices over the span,
        // allowing the last price to be extrapolated.
        (uint256 lo, uint256 hi) = _priceRange(t0, t);
        assertGe(got, lo);
        assertLe(got, hi);
    }

    function testFuzz_checkpointIdempotentSameBlock(uint256) public {
        uint256 n = pool.observationCount();
        pool.checkpoint();
        pool.checkpoint();
        pool.checkpoint();
        // Either no-op (already written this block) or a single write.
        uint256 n2 = pool.observationCount();
        assertTrue(n2 == n || n2 == n + 1);
        pool.checkpoint();
        assertEq(pool.observationCount(), n2);
    }

    function _walk(uint256 seed, uint256 steps) internal {
        uint256 rng = seed;
        vm.startPrank(alice);
        for (uint256 i; i < steps; ++i) {
            rng = uint256(keccak256(abi.encode(rng, i)));
            uint256 dt = bound(rng, 1, 25);
            _skip(dt);
            if (rng % 5 == 0) {
                pool.checkpoint();
                continue;
            }
            bool baseIn = rng % 2 == 0;
            if (baseIn) {
                uint256 amt = bound(rng >> 8, 1e16, 200e18);
                if (base.balanceOf(alice) >= amt) {
                    pool.swapExactIn(address(base), amt, 0, alice);
                } else {
                    pool.checkpoint();
                }
            } else {
                uint256 amt = bound(rng >> 8, 1e4, 200e6);
                if (usdc.balanceOf(alice) >= amt) {
                    pool.swapExactIn(address(usdc), amt, 0, alice);
                } else {
                    pool.checkpoint();
                }
            }
        }
        vm.stopPrank();
        _skip(3);
        pool.checkpoint();
    }

    function _priceRange(uint64 t0, uint64 t) internal view returns (uint256 lo, uint256 hi) {
        uint256 len = pool.observationLength();
        lo = type(uint256).max;
        hi = 0;
        for (uint256 i; i < len; ++i) {
            (uint32 ts,, uint192 price) = pool.observationAt(i);
            uint256 segStart = ts;
            uint256 segEnd = type(uint256).max;
            if (i + 1 < len) {
                (uint32 tsNext,,) = pool.observationAt(i + 1);
                segEnd = tsNext;
            }
            uint256 overlapLo = segStart > t0 ? segStart : t0;
            uint256 overlapHi = segEnd < t ? segEnd : t;
            if (overlapHi > overlapLo) {
                uint256 p = uint256(price);
                if (p < lo) lo = p;
                if (p > hi) hi = p;
            }
        }
        if (lo == type(uint256).max) {
            (,, uint192 lastP) = pool.latestObservation();
            lo = lastP;
            hi = lastP;
        }
    }
}
