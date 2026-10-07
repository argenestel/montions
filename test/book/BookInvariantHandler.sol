// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {MontionsBook} from "../../src/MontionsBook.sol";
import {MockResolver} from "./mocks/MockResolver.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Stateful actions used to exercise the Book's invariants.
contract BookInvariantHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant UNIT = 1_000_000;
    uint256 private constant TICK_UNIT = 10_000;
    bytes32 private constant _TRADE_TOPIC = keccak256("Trade(bytes32,uint64,address,address,uint8,uint64,bool)");

    MontionsBook public immutable book;
    MockResolver public immutable resolver;
    address[4] private _users = [address(0xA11CE), address(0xB0B), address(0xCA801), address(0xDA0E)];
    bytes32[7] private _series;
    uint64[7] private _expiries;
    uint64[] private _createdOrders;
    bool public priorityChecksPassed = true;
    bool public ownerSafetyPassed = true;

    constructor(MontionsBook book_, MockResolver resolver_) {
        book = book_;
        resolver = resolver_;
        uint64 soon = uint64(block.timestamp + book_.MIN_DURATION() + 1);
        for (uint256 i; i < 5; ++i) {
            _expiries[i] = soon + uint64(i);
            _series[i] = book_.createSeries(address(resolver_), abi.encode(i), _expiries[i]);
        }
        _expiries[5] = uint64(block.timestamp + 30 days);
        _expiries[6] = uint64(block.timestamp + 60 days);
        _series[5] = book_.createSeries(address(resolver_), abi.encode(uint256(5)), _expiries[5]);
        _series[6] = book_.createSeries(address(resolver_), abi.encode(uint256(6)), _expiries[6]);
    }

    /// @notice Returns a configured user by index.
    function userAt(uint256 index) external view returns (address) {
        return _users[index];
    }

    /// @notice Returns a configured series and expiry by index.
    function seriesAt(uint256 index) external view returns (bytes32, uint64) {
        return (_series[index], _expiries[index]);
    }

    /// @notice Returns the number of order ids created through this handler.
    function trackedOrderCount() external view returns (uint256) {
        return _createdOrders.length;
    }

    /// @notice Attempts a bounded order on one of the two long-lived open series.
    function place(
        uint8 userSeed,
        uint8 seriesSeed,
        bool bid,
        uint8 tickSeed,
        uint8 qtySeed,
        bool held,
        uint8 fillsSeed
    ) external {
        if (_createdOrders.length >= 48) return;
        address user = _users[userSeed % 4];
        uint256 seriesIndex = 5 + (seriesSeed % 2);
        bytes32 seriesId = _series[seriesIndex];
        uint8 tick = uint8(uint256(tickSeed) % 99 + 1);
        uint64 qty = uint64(uint256(qtySeed) % 3 + 1);
        IMontionsBook.Side side = bid ? IMontionsBook.Side.Bid : IMontionsBook.Side.Ask;
        bool fromHeld = held && !bid;
        IMontionsBook.SeriesInfo memory info = book.seriesInfo(seriesId);
        if (fromHeld && book.balanceOf(user, info.yesId) < qty) return;
        if (!fromHeld) {
            uint256 perUnit = bid ? tick : 100 - tick;
            if (book.cash(user) < uint256(qty) * perUnit * TICK_UNIT) return;
        }

        uint16 maxFills = uint16(uint256(fillsSeed) % 4 + 1);
        uint64[] memory expected = _expectedMakers(user, seriesId, side, tick, qty, maxFills);
        uint64 previousCount = book.orderCount();
        IMontionsBook.PlaceParams memory params = IMontionsBook.PlaceParams({
            seriesId: seriesId,
            side: side,
            tick: tick,
            qty: qty,
            fromHeld: fromHeld,
            tif: IMontionsBook.TIF.GTC,
            maxFills: maxFills
        });

        vm.recordLogs();
        vm.prank(user);
        try book.placeOrder(params) returns (uint64, uint64, uint64) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (book.orderCount() == previousCount + 1) {
                uint64 newId = book.orderCount();
                _createdOrders.push(newId);
                _checkTradeOrder(logs, expected);
            }
        } catch {
            vm.getRecordedLogs();
        }
    }

    /// @notice Attempts to cancel a currently open order through its maker.
    function cancel(uint64 idSeed) external {
        uint64 count = book.orderCount();
        if (count == 0) return;
        uint64 id = uint64(uint256(idSeed) % count + 1);
        IMontionsBook.OrderView memory order = book.orderInfo(id);
        if (!order.open) return;
        vm.prank(order.maker);
        try book.cancelOrder(id) {} catch {}
    }

    /// @notice Attempts to split collateral for one user and one open long-lived series.
    function split(uint8 userSeed, uint8 seriesSeed, uint8 qtySeed) external {
        address user = _users[userSeed % 4];
        bytes32 seriesId = _series[5 + (seriesSeed % 2)];
        uint64 qty = uint64(uint256(qtySeed) % 3 + 1);
        if (book.cash(user) < uint256(qty) * UNIT) return;
        vm.prank(user);
        try book.split(seriesId, qty) {} catch {}
    }

    /// @notice Attempts to merge paired tokens for one user and open series.
    function merge(uint8 userSeed, uint8 seriesSeed, uint8 qtySeed) external {
        address user = _users[userSeed % 4];
        bytes32 seriesId = _series[5 + (seriesSeed % 2)];
        IMontionsBook.SeriesInfo memory info = book.seriesInfo(seriesId);
        uint256 yes = book.balanceOf(user, info.yesId);
        uint256 no = book.balanceOf(user, info.noId);
        uint256 maximum = yes < no ? yes : no;
        if (maximum == 0) return;
        uint64 qty = uint64(uint256(qtySeed) % maximum + 1);
        vm.prank(user);
        try book.merge(seriesId, qty) {} catch {}
    }

    /// @notice Resolves one of the five expired short series to a deterministic result.
    function resolveReady(uint8 seriesSeed, bool yes) external {
        uint256 index = seriesSeed % 5;
        if (book.seriesInfo(_series[index]).status != IMontionsBook.Status.Open) return;
        if (block.timestamp < _expiries[index]) vm.warp(_expiries[index]);
        resolver.setResult(true, yes);
        try book.resolve(_series[index]) {} catch {}
    }

    /// @notice Voids the fifth short series after its resolver grace period.
    function resolveVoid() external {
        uint256 index = 4;
        if (book.seriesInfo(_series[index]).status != IMontionsBook.Status.Open) return;
        uint256 voidAt = uint256(_expiries[index]) + book.VOID_GRACE();
        if (block.timestamp < voidAt) vm.warp(voidAt);
        resolver.setResult(false, false);
        try book.resolve(_series[index]) {} catch {}
    }

    /// @notice Redeems all currently held outcomes for one user in a settled short series.
    function redeem(uint8 userSeed, uint8 seriesSeed) external {
        address user = _users[userSeed % 4];
        bytes32 seriesId = _series[seriesSeed % 5];
        IMontionsBook.SeriesInfo memory info = book.seriesInfo(seriesId);
        if (info.status == IMontionsBook.Status.Open) return;
        uint256 yesQty = book.balanceOf(user, info.yesId);
        uint256 noQty = book.balanceOf(user, info.noId);
        if (yesQty == 0 && noQty == 0) return;
        vm.prank(user);
        try book.redeem(seriesId, yesQty, noQty) returns (uint256) {} catch {}
    }

    /// @notice Exercises the only owner controls and records that no user assets changed.
    function ownerConfig(uint8 feeSeed) external {
        uint256[4] memory freeBefore;
        uint256[4] memory lockedBefore;
        uint256[56] memory tokensBefore;
        for (uint256 u; u < 4; ++u) {
            freeBefore[u] = book.cash(_users[u]);
            lockedBefore[u] = book.lockedCash(_users[u]);
            for (uint256 s; s < 7; ++s) {
                IMontionsBook.SeriesInfo memory info = book.seriesInfo(_series[s]);
                tokensBefore[(u * 7 + s) * 2] = book.balanceOf(_users[u], info.yesId);
                tokensBefore[(u * 7 + s) * 2 + 1] = book.balanceOf(_users[u], info.noId);
            }
        }
        vm.prank(book.owner());
        book.setFee(uint16(feeSeed % 101), address(0xFEE));
        vm.prank(book.owner());
        book.setResolverAllowed(address(resolver), true);
        for (uint256 u; u < 4; ++u) {
            if (book.cash(_users[u]) != freeBefore[u] || book.lockedCash(_users[u]) != lockedBefore[u]) {
                ownerSafetyPassed = false;
            }
            for (uint256 s; s < 7; ++s) {
                IMontionsBook.SeriesInfo memory info = book.seriesInfo(_series[s]);
                if (
                    book.balanceOf(_users[u], info.yesId) != tokensBefore[(u * 7 + s) * 2]
                        || book.balanceOf(_users[u], info.noId) != tokensBefore[(u * 7 + s) * 2 + 1]
                ) ownerSafetyPassed = false;
            }
        }
    }

    function _expectedMakers(
        address taker,
        bytes32 seriesId,
        IMontionsBook.Side side,
        uint8 limit,
        uint64 qty,
        uint16 maxFills
    ) private view returns (uint64[] memory expected) {
        uint256 total = _createdOrders.length;
        uint64[] memory candidates = new uint64[](total);
        uint256 candidateCount;
        for (uint256 i; i < total; ++i) {
            uint64 id = _createdOrders[i];
            IMontionsBook.OrderView memory order = book.orderInfo(id);
            bool crosses = side == IMontionsBook.Side.Bid ? order.tick <= limit : order.tick >= limit;
            if (order.open && order.seriesId == seriesId && order.side != side && crosses) {
                candidates[candidateCount++] = id;
            }
        }

        for (uint256 i = 1; i < candidateCount; ++i) {
            uint64 current = candidates[i];
            IMontionsBook.OrderView memory currentOrder = book.orderInfo(current);
            uint256 j = i;
            while (j != 0) {
                IMontionsBook.OrderView memory previousOrder = book.orderInfo(candidates[j - 1]);
                bool beforePrevious = side == IMontionsBook.Side.Bid
                    ? currentOrder.tick < previousOrder.tick
                        || (currentOrder.tick == previousOrder.tick && current < candidates[j - 1])
                    : currentOrder.tick > previousOrder.tick
                        || (currentOrder.tick == previousOrder.tick && current < candidates[j - 1]);
                if (!beforePrevious) break;
                candidates[j] = candidates[j - 1];
                --j;
            }
            candidates[j] = current;
        }

        expected = new uint64[](candidateCount);
        uint256 expectedCount;
        uint16 attempts;
        uint64 remaining = qty;
        for (uint256 i; i < candidateCount && attempts < maxFills && remaining != 0; ++i) {
            IMontionsBook.OrderView memory order = book.orderInfo(candidates[i]);
            ++attempts;
            if (order.maker == taker) continue;
            expected[expectedCount++] = candidates[i];
            remaining -= order.qty < remaining ? order.qty : remaining;
        }
        assembly {
            mstore(expected, expectedCount)
        }
    }

    function _checkTradeOrder(Vm.Log[] memory logs, uint64[] memory expected) private {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(book) || log.topics.length < 3 || log.topics[0] != _TRADE_TOPIC) continue;
            if (seen >= expected.length || uint64(uint256(log.topics[2])) != expected[seen]) {
                priorityChecksPassed = false;
            }
            ++seen;
        }
        if (seen != expected.length) priorityChecksPassed = false;
    }
}
