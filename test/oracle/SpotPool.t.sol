// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {TestUSDC} from "../../src/mocks/TestUSDC.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {SpotPool} from "../../src/oracle/SpotPool.sol";

contract SpotPoolTest is Test {
    TestUSDC internal usdc;
    MockERC20 internal base;
    SpotPool internal pool;

    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new TestUSDC(address(this));
        base = new MockERC20("Test MON", "tMON", 18, address(this));
        pool = new SpotPool(address(base), address(usdc), address(this));

        base.mint(address(this), 10_000_000e18);
        usdc.mint(address(this), 10_000_000e6);
        base.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
    }

    function test_priceWad_oneDollar() public {
        pool.addLiquidity(1_000e18, 1_000e6);
        assertEq(pool.priceWad(), 1e18);
    }

    function test_priceWad_oneEighty() public {
        pool.addLiquidity(1_000e18, 180_000e6);
        assertEq(pool.priceWad(), 180e18);
    }

    function test_addLiquidity_ownerOnlyAndZero() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.addLiquidity(1e18, 1e6);

        vm.expectRevert(SpotPool.ZeroAmount.selector);
        pool.addLiquidity(0, 0);
    }

    function test_addLiquidity_oneSidedSetsPrice() public {
        pool.addLiquidity(1_000e18, 1_000e6);
        pool.addLiquidity(0, 1_000e6);
        assertEq(pool.priceWad(), 2e18);
        // 1_000e18 base + 2_000e6 quote is $2; adding another 1_000e18 base restores $1.
        pool.addLiquidity(1_000e18, 0);
        assertEq(pool.priceWad(), 1e18);
    }

    function test_swap_kNeverDecreasesAndFeeAccrues() public {
        pool.addLiquidity(100_000e18, 100_000e6);
        uint256 k0 = pool.baseReserve() * pool.quoteReserve();

        uint256 out = pool.swapExactIn(address(usdc), 1_000e6, 0, address(this));
        assertGt(out, 0);
        uint256 k1 = pool.baseReserve() * pool.quoteReserve();
        assertGt(k1, k0, "fee must accrue into k");

        out = pool.swapExactIn(address(base), 500e18, 0, address(this));
        assertGt(out, 0);
        uint256 k2 = pool.baseReserve() * pool.quoteReserve();
        assertGt(k2, k1);
    }

    function test_swap_minOutAndInvalidToken() public {
        pool.addLiquidity(100_000e18, 100_000e6);
        vm.expectRevert();
        pool.swapExactIn(address(usdc), 1e6, 100_000e18, address(this));

        vm.expectRevert(SpotPool.InvalidToken.selector);
        pool.swapExactIn(address(0xB0B), 1e6, 0, address(this));

        vm.expectRevert(SpotPool.ZeroAmount.selector);
        pool.swapExactIn(address(usdc), 0, 0, address(this));
    }

    function test_swap_sendsOutputToRecipient() public {
        pool.addLiquidity(100_000e18, 100_000e6);
        uint256 out = pool.swapExactIn(address(usdc), 10e6, 0, alice);
        assertEq(base.balanceOf(alice), out);
        assertEq(usdc.balanceOf(address(pool)), 100_010e6);
    }

    function test_observation_firstSwapOfTimestampAndSameTimestamp() public {
        pool.addLiquidity(100_000e18, 100_000e6);
        assertEq(pool.observationCount(), 0);

        pool.swapExactIn(address(usdc), 10e6, 0, address(this));
        assertEq(pool.observationCount(), 1);
        uint192 p1 = _lastPrice();

        // second swap, same timestamp: no new slot, price refreshed
        pool.swapExactIn(address(usdc), 10e6, 0, address(this));
        assertEq(pool.observationCount(), 1);
        uint192 p2 = _lastPrice();
        assertGt(uint256(p2), uint256(p1));

        vm.warp(block.timestamp + 12);
        pool.swapExactIn(address(base), 10e18, 0, address(this));
        assertEq(pool.observationCount(), 2);
        (uint32 ts0,,) = pool.observationAt(0);
        (uint32 ts1,,) = pool.observationAt(1);
        assertEq(ts1, ts0 + 12);
    }

    function test_checkpoint_writesAndSameTimestampRefreshesPrice() public {
        pool.addLiquidity(1_000e18, 1_000e6);
        pool.checkpoint();
        assertEq(pool.observationCount(), 1);
        (uint32 ts,, uint192 p0) = pool.latestObservation();
        assertEq(uint256(p0), 1e18);

        pool.addLiquidity(0, 1_000e6); // $2, same timestamp
        pool.checkpoint();
        assertEq(pool.observationCount(), 1);
        (uint32 ts1,, uint192 p1) = pool.latestObservation();
        assertEq(ts1, ts);
        assertEq(uint256(p1), 2e18);

        vm.warp(block.timestamp + 5);
        pool.checkpoint();
        assertEq(pool.observationCount(), 2);
    }

    function test_checkpoint_emptyReverts() public {
        vm.expectRevert(SpotPool.EmptyReserves.selector);
        pool.checkpoint();
    }

    function test_fuzz_swapKNeverDecreases(uint256 amountIn, bool quoteIn) public {
        pool.addLiquidity(100_000e18, 100_000e6);
        amountIn = bound(amountIn, 1, quoteIn ? uint256(10_000e6) : uint256(10_000e18));
        uint256 k0 = pool.baseReserve() * pool.quoteReserve();
        address tokenIn = quoteIn ? address(usdc) : address(base);
        pool.swapExactIn(tokenIn, amountIn, 0, address(this));
        uint256 k1 = pool.baseReserve() * pool.quoteReserve();
        assertGe(k1, k0);
        assertGt(k1, k0);
    }

    function test_ringWraparound() public {
        pool.addLiquidity(1_000e18, 1_000e6);
        pool.checkpoint();
        uint32 firstTs = uint32(block.timestamp);
        for (uint256 i = 1; i <= 1024; ++i) {
            vm.warp(firstTs + i);
            pool.checkpoint();
        }
        assertEq(pool.observationCount(), 1025);
        assertEq(pool.observationLength(), 1024);
        assertEq(pool.nextObsIndex(), 1);
        (uint32 oldest,,) = pool.observationAt(0);
        assertEq(oldest, firstTs + 1);
        (uint32 newest,,) = pool.observationAt(1023);
        assertEq(newest, firstTs + 1024);
    }

    function test_gas_swapExactIn() public {
        pool.addLiquidity(100_000e18, 100_000e6);
        // warm the first observation slot so the measured swap is the steady-state path
        pool.checkpoint();
        vm.warp(block.timestamp + 1);

        pool.swapExactIn(address(usdc), 100e6, 0, address(this));
        vm.snapshotGasLastCall("SpotPool.swapExactIn");
    }

    function _lastPrice() internal view returns (uint192 price) {
        (,, price) = pool.latestObservation();
    }
}
