// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PythTestBase} from "./PythTestBase.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {IResolver} from "../../src/interfaces/IResolver.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract PythSettlementBookTest is PythTestBase {
    function testNoUpdateLeavesNotReadyThenRealBookVoidsAndRedeemsHalf() public {
        _deployBook();
        uint64 expiry = uint64(START + 120);
        bytes32 seriesId = _createSeries(expiry, 1e18, true);

        vm.prank(ALICE);
        book.deposit(UNIT);
        vm.prank(ALICE);
        book.split(seriesId, 1);

        vm.warp(uint256(expiry) + 1);
        bytes[] memory noUpdates = new bytes[](0);
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        resolver.settle(ASSET, expiry, noUpdates);
        (bool ready,) = resolver.resolve(_data(1e18, true, 300), expiry);
        assertFalse(ready);
        vm.expectRevert(IMontionsBook.NotExpired.selector);
        book.resolve(seriesId);

        vm.warp(uint256(expiry) + book.VOID_GRACE());
        book.resolve(seriesId);
        assertEq(uint256(book.seriesInfo(seriesId).status), uint256(IMontionsBook.Status.Void));
        vm.prank(ALICE);
        uint256 payout = book.redeem(seriesId, 1, 1);
        assertEq(payout, UNIT);
        assertEq(book.pool(seriesId), 0);
    }

    function testInvalidConfidenceTakesRealBookVoidPath() public {
        _deployBook();
        uint64 expiry = uint64(START + 120);
        bytes32 seriesId = _createSeries(expiry, 1e18, true);
        vm.prank(ALICE);
        book.deposit(UNIT);
        vm.prank(ALICE);
        book.split(seriesId, 1);

        bytes[] memory updateData = _update(FEED, 100_000_000, 2_000_001, -8, uint256(expiry) + 20);
        vm.warp(uint256(expiry) + 21);
        resolver.settle{value: 100}(ASSET, expiry, updateData);
        (bool ready,) = resolver.resolve(_data(1e18, true, 300), expiry);
        assertFalse(ready);

        vm.warp(uint256(expiry) + book.VOID_GRACE());
        book.resolve(seriesId);
        assertEq(uint256(book.seriesInfo(seriesId).status), uint256(IMontionsBook.Status.Void));
        vm.prank(ALICE);
        assertEq(book.redeem(seriesId, 1, 1), UNIT);
    }

    function testEndToEndCreateTradeSettleResolveAndRedeem() public {
        _deployBook();
        uint64 expiry = uint64(START + 600);
        bytes32 seriesId = _createSeries(expiry, 1e18, true);

        vm.prank(ALICE);
        book.deposit(UNIT);
        vm.prank(BOB);
        book.deposit(UNIT);
        (, uint64 askFilled, uint64 askResting) = _bookPlace(ALICE, seriesId, IMontionsBook.Side.Ask, 40, 1);
        assertEq(askFilled, 0);
        assertEq(askResting, 1);
        (, uint64 bidFilled, uint64 bidResting) = _bookPlace(BOB, seriesId, IMontionsBook.Side.Bid, 40, 1);
        assertEq(bidFilled, 1);
        assertEq(bidResting, 0);
        assertEq(book.pool(seriesId), UNIT);

        uint256 yesId = book.seriesInfo(seriesId).yesId;
        uint256 noId = book.seriesInfo(seriesId).noId;
        assertEq(book.balanceOf(BOB, yesId), 1);
        assertEq(book.balanceOf(ALICE, noId), 1);

        bytes[] memory updateData = _update(FEED, 150_000_000, 1_000_000, -8, uint256(expiry) + 300);
        vm.warp(uint256(expiry) + 301);
        resolver.settle{value: 100}(ASSET, expiry, updateData);
        book.resolve(seriesId);
        IMontionsBook.SeriesInfo memory info = book.seriesInfo(seriesId);
        assertEq(uint256(info.status), uint256(IMontionsBook.Status.Resolved));
        assertTrue(info.yes);

        vm.prank(BOB);
        assertEq(book.redeem(seriesId, 1, 0), UNIT);
        vm.prank(ALICE);
        assertEq(book.redeem(seriesId, 0, 1), 0);
        assertEq(book.cash(BOB), 1_600_000);
        assertEq(book.pool(seriesId), 0);
        assertEq(book.balanceOf(BOB, yesId), 0);
        assertEq(book.balanceOf(ALICE, noId), 0);
    }
}
