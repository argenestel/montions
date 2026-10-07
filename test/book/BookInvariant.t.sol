// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {MontionsBook} from "../../src/MontionsBook.sol";
import {TestUSDC} from "./mocks/TestUSDC.sol";
import {MockResolver} from "./mocks/MockResolver.sol";
import {BookInvariantHandler} from "./BookInvariantHandler.sol";

/// @notice Stateful assertions for the seven normative Book invariants.
contract BookInvariantTest is Test {
    uint256 private constant UNIT = 1_000_000;
    uint256 private constant TICK_UNIT = 10_000;
    address private constant OWNER = address(0xB00C);

    TestUSDC private usdc;
    MockResolver private resolver;
    MontionsBook private book;
    BookInvariantHandler private handler;
    address[4] private users = [address(0xA11CE), address(0xB0B), address(0xCA801), address(0xDA0E)];

    function setUp() public {
        usdc = new TestUSDC(address(this));
        resolver = new MockResolver();
        book = new MontionsBook(address(usdc), OWNER);
        vm.prank(OWNER);
        book.setResolverAllowed(address(resolver), true);

        for (uint256 i; i < users.length; ++i) {
            usdc.mint(users[i], 100 * UNIT);
            vm.prank(users[i]);
            usdc.approve(address(book), type(uint256).max);
            vm.prank(users[i]);
            book.deposit(100 * UNIT);
        }

        handler = new BookInvariantHandler(book, resolver);
        for (uint256 u; u < users.length; ++u) {
            for (uint256 s; s < 5; ++s) {
                (bytes32 seriesId,) = handler.seriesAt(s);
                vm.prank(users[u]);
                book.split(seriesId, 1);
            }
        }
        (bytes32 firstExpirySeries, uint64 firstExpiry) = handler.seriesAt(0);
        firstExpirySeries;
        vm.warp(firstExpiry);

        targetContract(address(handler));
    }

    /// @notice Open-series collateral equals both outcome supplies.
    function invariant_01_OpenPoolBacksBothOutcomes() public view {
        for (uint256 i; i < 7; ++i) {
            (bytes32 seriesId,) = handler.seriesAt(i);
            if (book.seriesInfo(seriesId).status != IMontionsBook.Status.Open) continue;
            uint256 poolAmount = book.pool(seriesId);
            assertEq(poolAmount, book.totalSupply(book.seriesInfo(seriesId).yesId) * UNIT);
            assertEq(poolAmount, book.totalSupply(book.seriesInfo(seriesId).noId) * UNIT);
        }
    }

    /// @notice Resolved winning supply and void remaining supply exactly describe the pool.
    function invariant_02_SettledPoolsMatchRemainingSupply() public view {
        for (uint256 i; i < 7; ++i) {
            (bytes32 seriesId,) = handler.seriesAt(i);
            IMontionsBook.SeriesInfo memory info = book.seriesInfo(seriesId);
            uint256 yesSupply = book.totalSupply(info.yesId);
            uint256 noSupply = book.totalSupply(info.noId);
            if (info.status == IMontionsBook.Status.Resolved) {
                assertEq(book.pool(seriesId), (info.yes ? yesSupply : noSupply) * UNIT);
            } else if (info.status == IMontionsBook.Status.Void) {
                assertEq(book.pool(seriesId) * 2, (yesSupply + noSupply) * UNIT);
            }
        }
    }

    /// @notice Book collateral exactly equals all internal liabilities.
    function invariant_03_CollateralMatchesLedger() public view {
        uint256 liabilities = book.protocolFees();
        for (uint256 i; i < users.length; ++i) {
            liabilities += book.cash(users[i]) + book.lockedCash(users[i]);
        }
        for (uint256 i; i < 7; ++i) {
            (bytes32 seriesId,) = handler.seriesAt(i);
            liabilities += book.pool(seriesId);
        }
        assertEq(usdc.balanceOf(address(book)), liabilities);
    }

    /// @notice Per-user locked cash equals collateral for their open orders.
    function invariant_04_LockedCashMatchesOpenOrders() public view {
        uint256[4] memory lockedByUser;
        uint64 count = book.orderCount();
        for (uint64 id = 1; id <= count; ++id) {
            IMontionsBook.OrderView memory order = book.orderInfo(id);
            if (!order.open || order.fromHeld) continue;
            uint256 perContract = order.side == IMontionsBook.Side.Bid ? order.tick : 100 - order.tick;
            uint256 escrow = uint256(order.qty) * perContract * TICK_UNIT;
            for (uint256 u; u < users.length; ++u) {
                if (users[u] == order.maker) lockedByUser[u] += escrow;
            }
        }
        for (uint256 u; u < users.length; ++u) {
            assertEq(book.lockedCash(users[u]), lockedByUser[u]);
        }
    }

    /// @notice Aggregated depth matches every open order at each tick and side.
    function invariant_05_DepthMatchesOpenOrders() public view {
        uint64 count = book.orderCount();
        for (uint256 s; s < 7; ++s) {
            (bytes32 seriesId,) = handler.seriesAt(s);
            uint64[] memory bidTotals = new uint64[](100);
            uint64[] memory askTotals = new uint64[](100);
            for (uint64 id = 1; id <= count; ++id) {
                IMontionsBook.OrderView memory order = book.orderInfo(id);
                if (!order.open || order.seriesId != seriesId) continue;
                if (order.side == IMontionsBook.Side.Bid) bidTotals[order.tick] += order.qty;
                else askTotals[order.tick] += order.qty;
            }

            _assertDepth(seriesId, IMontionsBook.Side.Bid, bidTotals);
            _assertDepth(seriesId, IMontionsBook.Side.Ask, askTotals);
        }
    }

    /// @notice Handler-observed fills always use the next best price-time maker.
    function invariant_06_PriceTimePriorityIsPreserved() public view {
        assertTrue(handler.priorityChecksPassed());
    }

    /// @notice Owner configuration actions never decrease user cash, locked cash, or tokens.
    function invariant_07_OwnerCannotReduceUserAssets() public view {
        assertTrue(handler.ownerSafetyPassed());
    }

    function _assertDepth(bytes32 seriesId, IMontionsBook.Side side, uint64[] memory expected) private view {
        IMontionsBook.Level[] memory levels = book.depth(seriesId, side, 99);
        uint8 previous;
        for (uint256 i; i < levels.length; ++i) {
            IMontionsBook.Level memory level = levels[i];
            assertGt(level.qty, 0);
            assertEq(level.qty, expected[level.tick]);
            expected[level.tick] = 0;
            if (previous != 0) {
                if (side == IMontionsBook.Side.Bid) assertLt(level.tick, previous);
                else assertGt(level.tick, previous);
            }
            previous = level.tick;
        }
        for (uint256 tick = 1; tick < 100; ++tick) {
            assertEq(expected[tick], 0);
        }

        (uint8 bidTick,, uint8 askTick,) = book.bestBidAsk(seriesId);
        if (side == IMontionsBook.Side.Bid) {
            assertEq(bidTick, levels.length == 0 ? 0 : levels[0].tick);
        } else {
            assertEq(askTick, levels.length == 0 ? 0 : levels[0].tick);
        }
    }
}
