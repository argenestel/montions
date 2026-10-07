// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BookTestBase} from "./BookTestBase.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {MontionsBook} from "../../src/MontionsBook.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract BookSafetyTest is BookTestBase {
    event PausedSet(bool paused);
    event CollateralCapSet(uint256 cap);
    event SeriesPoolCapSet(uint256 cap);
    event NativeSwept(address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event OwnershipHandoverRequested(address indexed pendingOwner);
    event OwnershipHandoverCanceled(address indexed pendingOwner);

    function testPauseBlocksOnlyNewRiskAndResumes() public {
        vm.expectEmit(false, false, false, true, address(book));
        emit PausedSet(true);
        vm.prank(BOOK_OWNER);
        book.setPaused(true);
        assertTrue(book.paused());

        vm.expectRevert(MontionsBook.Paused.selector);
        vm.prank(ALICE);
        book.createSeries(address(resolver), bytes("paused"), expiry + 10);

        vm.expectRevert(MontionsBook.Paused.selector);
        vm.prank(ALICE);
        book.placeOrder(_params(series, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.GTC, 0));

        vm.expectRevert(MontionsBook.Paused.selector);
        vm.prank(ALICE);
        book.split(series, 1);

        vm.expectRevert(MontionsBook.Paused.selector);
        vm.prank(ALICE);
        book.deposit(1);

        vm.expectRevert(MontionsBook.Paused.selector);
        vm.prank(ALICE);
        book.depositWithPermit(1, block.timestamp + 1 days, 0, bytes32(0), bytes32(0));

        vm.prank(BOOK_OWNER);
        book.setPaused(false);
        assertFalse(book.paused());
        _deposit(ALICE, 2 * UNIT);
        bytes32 created = _createSeries(expiry + 10);
        assertTrue(book.seriesInfo(created).status == IMontionsBook.Status.Open);
        _place(ALICE, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.GTC, 0);
        vm.prank(ALICE);
        book.split(series, 1);
    }

    function testAllExitAndSettlementPathsRemainAvailableWhilePaused() public {
        _deposit(ALICE, 10 * UNIT);
        _deposit(CAROL, 2 * UNIT);
        _deposit(DAVE, 2 * UNIT);
        vm.prank(ALICE);
        book.split(series, 2);

        vm.prank(BOOK_OWNER);
        book.setFee(100, BOB);
        _place(CAROL, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        (, uint64 feeFill,) = _place(DAVE, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.IOC, 0);
        assertEq(feeFill, 1);
        assertGt(book.protocolFees(), 0);

        (uint64 cancelOne,,) = _place(ALICE, IMontionsBook.Side.Bid, 20, 1, false, IMontionsBook.TIF.GTC, 0);
        (uint64 cancelTwo,,) = _place(ALICE, IMontionsBook.Side.Bid, 30, 1, false, IMontionsBook.TIF.GTC, 0);
        (uint64 cancelThree,,) = _place(ALICE, IMontionsBook.Side.Ask, 80, 1, false, IMontionsBook.TIF.GTC, 0);

        vm.prank(BOOK_OWNER);
        book.setPaused(true);

        vm.prank(ALICE);
        book.cancelOrder(cancelOne);
        uint64[] memory batch = new uint64[](2);
        batch[0] = cancelTwo;
        batch[1] = cancelThree;
        vm.prank(ALICE);
        book.cancelOrders(batch);
        assertEq(book.lockedCash(ALICE), 0);

        vm.prank(ALICE);
        book.merge(series, 1);
        uint256 yesId = _yesId();
        uint256 noId = _noId();
        vm.prank(ALICE);
        book.safeTransferFrom(ALICE, BOB, yesId, 1, "paused transfer");
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = noId;
        amounts[0] = 1;
        vm.prank(ALICE);
        book.safeBatchTransferFrom(ALICE, BOB, ids, amounts, "paused batch");
        vm.prank(ALICE);
        book.setApprovalForAll(CAROL, true);
        assertTrue(book.isApprovedForAll(ALICE, CAROL));

        resolver.setResult(true, true);
        vm.warp(uint256(expiry) + 1);
        book.resolve(series);
        vm.prank(BOB);
        assertEq(book.redeem(series, 1, 1), UNIT);
        vm.prank(ALICE);
        book.withdraw(UNIT);
        uint256 feesBefore = book.protocolFees();
        vm.prank(CAROL);
        book.withdrawFees();
        assertEq(book.protocolFees(), 0);
        assertGt(feesBefore, 0);
        assertTrue(book.paused());
        _assertSolvent();
    }

    function testBookRequiresSixDecimalCollateral() public {
        WrongDecimalsCollateral token = new WrongDecimalsCollateral();
        vm.expectRevert(MontionsBook.InvalidCollateralDecimals.selector);
        new MontionsBook(address(token), BOOK_OWNER);
    }

    function testCollateralCapTracksAllLedgerCollateralAndMayBeLoweredBelowUsage() public {
        (uint256 initialCollateralCap, uint256 initialPoolCap) = book.caps();
        assertEq(initialCollateralCap, type(uint256).max);
        assertEq(initialPoolCap, type(uint256).max);

        vm.expectEmit(false, false, false, true, address(book));
        emit CollateralCapSet(UNIT);
        vm.prank(BOOK_OWNER);
        book.setCollateralCap(UNIT);
        _deposit(ALICE, UNIT);
        assertEq(book.totalCollateral(), UNIT);
        assertEq(usdc.balanceOf(address(book)), book.totalCollateral());

        vm.prank(BOOK_OWNER);
        book.setCollateralCap(UNIT / 2);
        vm.expectRevert(MontionsBook.CollateralCapExceeded.selector);
        vm.prank(ALICE);
        book.deposit(1);

        vm.prank(ALICE);
        book.withdraw(UNIT / 2);
        assertEq(book.totalCollateral(), UNIT / 2);
        vm.expectRevert(MontionsBook.CollateralCapExceeded.selector);
        vm.prank(ALICE);
        book.deposit(1);
        _assertSolvent();
    }

    function testSplitCapAndPartialFillAtSeriesCap() public {
        _deposit(ALICE, 5 * UNIT);
        _deposit(BOB, 5 * UNIT);
        vm.expectEmit(false, false, false, true, address(book));
        emit SeriesPoolCapSet(2 * UNIT);
        vm.prank(BOOK_OWNER);
        book.setSeriesPoolCap(2 * UNIT);

        vm.expectRevert(MontionsBook.SeriesCapExceeded.selector);
        vm.prank(ALICE);
        book.split(series, 3);

        (uint64 ask,,) = _place(ALICE, IMontionsBook.Side.Ask, 40, 3, false, IMontionsBook.TIF.GTC, 0);
        (uint64 bid, uint64 filled, uint64 resting) =
            _place(BOB, IMontionsBook.Side.Bid, 50, 3, false, IMontionsBook.TIF.GTC, 0);

        // Fill exactly the two contracts of remaining pool capacity, then stop. The
        // still-crossing one-contract GTC remainder is refunded rather than rested.
        assertEq(filled, 2);
        assertEq(resting, 0);
        assertEq(book.orderInfo(bid).qty, 0);
        assertEq(book.orderInfo(ask).qty, 1);
        assertTrue(book.orderInfo(ask).open);
        assertEq(book.pool(series), 2 * UNIT);
        assertEq(book.totalSupply(_yesId()), 2);
        assertEq(book.totalSupply(_noId()), 2);
        _assertSolvent();
    }

    function testSeriesCapMayBeLoweredBelowUsageAndBlocksOnlyNewPairs() public {
        _deposit(ALICE, 3 * UNIT);
        vm.prank(ALICE);
        book.split(series, 2);
        vm.prank(BOOK_OWNER);
        book.setSeriesPoolCap(UNIT);
        assertEq(book.pool(series), 2 * UNIT);

        vm.expectRevert(MontionsBook.SeriesCapExceeded.selector);
        vm.prank(ALICE);
        book.split(series, 1);
        vm.prank(ALICE);
        book.merge(series, 1);
        assertEq(book.pool(series), UNIT);
        vm.expectRevert(MontionsBook.SeriesCapExceeded.selector);
        vm.prank(ALICE);
        book.split(series, 1);
    }

    function testNativeCurrencyCanOnlyEnterThroughMulticallAndIsSweptSeparately() public {
        _deposit(ALICE, UNIT);
        vm.prank(ALICE);
        book.split(series, 1);
        uint256 collateralBefore = usdc.balanceOf(address(book));
        uint256 trackedBefore = book.totalCollateral();
        uint256 yesBefore = book.balanceOf(ALICE, _yesId());
        uint256 noBefore = book.balanceOf(ALICE, _noId());
        bytes[] memory noCalls = new bytes[](0);
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        book.multicall{value: 1 ether}(noCalls);
        assertEq(address(book).balance, 1 ether);
        assertEq(usdc.balanceOf(address(book)), collateralBefore);

        vm.expectEmit(true, false, false, true, address(book));
        emit NativeSwept(DAVE, 1 ether);
        vm.prank(BOOK_OWNER);
        book.sweepNative(DAVE);
        assertEq(address(book).balance, 0);
        assertEq(address(DAVE).balance, 1 ether);
        assertEq(usdc.balanceOf(address(book)), collateralBefore);
        assertEq(book.totalCollateral(), trackedBefore);
        assertEq(book.balanceOf(ALICE, _yesId()), yesBefore);
        assertEq(book.balanceOf(ALICE, _noId()), noBefore);

        vm.deal(ALICE, 1 wei);
        vm.prank(ALICE);
        (bool success,) = address(book).call{value: 1 wei}("");
        assertFalse(success);
    }

    function testOwnershipHandoverIsTwoStepAndCannotBeRenouncedOrTransferredDirectly() public {
        vm.expectRevert(MontionsBook.TwoStepOwnershipRequired.selector);
        vm.prank(BOOK_OWNER);
        book.transferOwnership(ALICE);
        vm.expectRevert(MontionsBook.OwnershipRenunciationDisabled.selector);
        vm.prank(BOOK_OWNER);
        book.renounceOwnership();

        vm.expectEmit(true, false, false, true, address(book));
        emit OwnershipHandoverRequested(ALICE);
        vm.prank(ALICE);
        book.requestOwnershipHandover();
        assertGt(book.ownershipHandoverExpiresAt(ALICE), block.timestamp);
        vm.expectEmit(true, true, false, true, address(book));
        emit OwnershipTransferred(BOOK_OWNER, ALICE);
        vm.prank(BOOK_OWNER);
        book.completeOwnershipHandover(ALICE);
        assertEq(book.owner(), ALICE);

        vm.prank(BOB);
        book.requestOwnershipHandover();
        vm.expectEmit(true, false, false, true, address(book));
        emit OwnershipHandoverCanceled(BOB);
        vm.prank(BOB);
        book.cancelOwnershipHandover();
        vm.expectRevert(Ownable.NoHandoverRequest.selector);
        vm.prank(ALICE);
        book.completeOwnershipHandover(BOB);
    }

    function testSafetyControlsAreOwnerOnly() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(ALICE);
        book.setPaused(true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(ALICE);
        book.setCollateralCap(0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(ALICE);
        book.setSeriesPoolCap(0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(ALICE);
        book.sweepNative(ALICE);
    }
}

contract WrongDecimalsCollateral {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
