// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {TestUSDC} from "../../src/mocks/TestUSDC.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {SpotPool} from "../../src/oracle/SpotPool.sol";
import {OracleHub} from "../../src/oracle/OracleHub.sol";

abstract contract OracleTestBase is Test {
    uint256 internal constant START_TS = 1_700_000_000;
    uint256 internal constant DEEP_BASE = 1_000_000e18;
    uint256 internal constant DEEP_QUOTE = 1_000_000e6; // $1 spot
    uint256 internal constant BPS_1 = 1e14; // 1 bps in relative 1e18

    TestUSDC internal usdc;
    MockERC20 internal base;
    SpotPool internal pool;
    OracleHub internal hub;
    bytes32 internal assetId;

    address internal alice;
    address internal bob;

    function _setUpOracle() internal {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.warp(START_TS);
        vm.roll(10);
        usdc = new TestUSDC(address(this));
        base = new MockERC20("Test MON", "tMON", 18, address(this));
        pool = new SpotPool(address(base), address(usdc), address(this));
        hub = new OracleHub(address(this));
        assetId = keccak256("MON");
        hub.registerAsset(assetId, address(pool));
    }

    function _seed(uint256 baseAmt, uint256 quoteAmt) internal {
        base.mint(address(this), baseAmt);
        usdc.mint(address(this), quoteAmt);
        base.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.addLiquidity(baseAmt, quoteAmt);
    }

    function _seedDeep() internal {
        _seed(DEEP_BASE, DEEP_QUOTE);
    }

    function _skip(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    function _fund(address who, uint256 baseAmt, uint256 quoteAmt) internal {
        if (baseAmt != 0) base.mint(who, baseAmt);
        if (quoteAmt != 0) usdc.mint(who, quoteAmt);
        vm.startPrank(who);
        base.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _expectedOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        uint256 ainFee = amountIn * 997;
        uint256 denom = reserveIn * 1000 + ainFee;
        return FixedPointMathLib.fullMulDiv(ainFee, reserveOut, denom);
    }

    /// @dev Piecewise-constant TWAP over `(t - window, t]` from the pool ring.
    function _refTwap(SpotPool p, uint64 t, uint32 window) internal view returns (uint256) {
        if (window == 0 || t < window) revert("ref: window");
        uint64 t0 = t - window;
        uint256 len = p.observationLength();
        if (len == 0) revert("ref: empty");
        (uint32 firstTs,,) = p.observationAt(0);
        if (t0 < firstTs) revert("ref: history");

        uint256 integral;
        for (uint256 i; i < len; ++i) {
            (uint32 ts,, uint192 price) = p.observationAt(i);
            uint256 segStart = ts;
            uint256 segEnd = type(uint256).max;
            if (i + 1 < len) {
                (uint32 tsNext,,) = p.observationAt(i + 1);
                segEnd = tsNext;
            }
            uint256 lo = segStart > t0 ? segStart : t0;
            uint256 hi = segEnd < t ? segEnd : t;
            if (hi > lo) integral += uint256(price) * (hi - lo);
        }
        return integral / uint256(window);
    }
}
