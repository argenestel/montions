// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BookTestBase} from "./BookTestBase.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {TestUSDC} from "./mocks/TestUSDC.sol";
import {MontionsBook} from "../../src/MontionsBook.sol";
import {MockResolver} from "./mocks/MockResolver.sol";

contract BookSemanticsTest is BookTestBase {
    function testSeriesIdRegistryAndPaging() public {
        bytes32 expected = keccak256(abi.encode(address(resolver), bytes("fixture"), expiry));
        assertEq(series, expected);
        assertEq(book.seriesIdOf(address(resolver), bytes("fixture"), expiry), expected);
        assertEq(_yesId(), uint256(keccak256(abi.encode(series, "YES"))));
        assertEq(_noId(), uint256(keccak256(abi.encode(series, "NO"))));
        assertEq(book.seriesCount(), 1);
        assertEq(book.seriesIdAt(0), series);

        vm.expectRevert(IMontionsBook.SeriesExists.selector);
        vm.prank(ALICE);
        book.createSeries(address(resolver), bytes("fixture"), expiry);

        bytes32 second = _newSeries(expiry + 1);
        bytes32 third = _newSeries(expiry + 2);
        bytes32[] memory page = book.seriesIds(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0], second);
        page = book.seriesIds(2, 9);
        assertEq(page.length, 1);
        assertEq(page[0], third);
        assertEq(book.seriesIds(3, 1).length, 0);
    }

    function testCreateSeriesRequiresAllowedValidResolverAndBoundedExpiry() public {
        MockResolver other = new MockResolver();
        uint64 minExpiry = uint64(block.timestamp + book.MIN_DURATION() - 1);
        uint64 maxExpiry = uint64(block.timestamp + book.MAX_DURATION() + 1);
        vm.expectRevert(IMontionsBook.ResolverNotAllowed.selector);
        vm.prank(ALICE);
        book.createSeries(address(other), bytes("fixture"), expiry);

        vm.expectRevert(IMontionsBook.BadExpiry.selector);
        vm.prank(ALICE);
        book.createSeries(address(resolver), bytes("early"), minExpiry);

        vm.expectRevert(IMontionsBook.BadExpiry.selector);
        vm.prank(ALICE);
        book.createSeries(address(resolver), bytes("late"), maxExpiry);

        resolver.setReverts(true, false);
        vm.expectRevert(MontionsBook.ResolverValidationFailed.selector);
        vm.prank(ALICE);
        book.createSeries(address(resolver), bytes("bad"), expiry + 10);
    }

    function testDepositWithdrawAndPermitMulticall() public {
        _deposit(ALICE, 2_000_000);
        assertEq(book.cash(ALICE), 2_000_000);
        vm.prank(ALICE);
        book.withdraw(250_000);
        assertEq(book.cash(ALICE), 1_750_000);

        uint256 privateKey = 0xC0FFEE;
        address signer = vm.addr(privateKey);
        uint256 amount = 2_000_000;
        usdc.mint(signer, amount);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, signer, address(book), amount, usdc.nonces(signer), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(book.depositWithPermit, (amount, deadline, v, r, s));
        IMontionsBook.PlaceParams memory order =
            _params(series, IMontionsBook.Side.Bid, 30, 1, false, IMontionsBook.TIF.GTC, 0);
        calls[1] = abi.encodeCall(book.placeOrder, (order));
        vm.prank(signer);
        book.multicall(calls);

        assertEq(book.cash(signer), 1_700_000);
        assertEq(book.lockedCash(signer), 300_000);
        assertTrue(book.orderInfo(book.orderCount()).open);
        assertEq(book.pool(series), 0);
    }

    function testBadTickAndZeroQuantityRevert() public {
        _deposit(ALICE, 5_000_000);
        vm.expectRevert(IMontionsBook.BadTick.selector);
        vm.prank(ALICE);
        book.placeOrder(_params(series, IMontionsBook.Side.Bid, 0, 1, false, IMontionsBook.TIF.GTC, 0));

        vm.expectRevert(IMontionsBook.BadTick.selector);
        vm.prank(ALICE);
        book.placeOrder(_params(series, IMontionsBook.Side.Ask, 100, 1, false, IMontionsBook.TIF.GTC, 0));

        vm.expectRevert(IMontionsBook.BadQty.selector);
        vm.prank(ALICE);
        book.placeOrder(_params(series, IMontionsBook.Side.Bid, 50, 0, false, IMontionsBook.TIF.GTC, 0));
    }

    function testPriceTimePriorityUsesMakerTickAndUpdatesViews() public {
        _deposit(ALICE, 5_000_000);
        _deposit(BOB, 5_000_000);
        _deposit(CAROL, 5_000_000);

        (uint64 aliceAsk,,) = _place(ALICE, IMontionsBook.Side.Ask, 40, 3, false, IMontionsBook.TIF.GTC, 0);
        (uint64 bobAsk,,) = _place(BOB, IMontionsBook.Side.Ask, 35, 2, false, IMontionsBook.TIF.GTC, 0);
        (uint64 takerId, uint64 filled, uint64 resting) =
            _place(CAROL, IMontionsBook.Side.Bid, 50, 4, false, IMontionsBook.TIF.GTC, 0);

        assertEq(takerId, 3);
        assertEq(filled, 4);
        assertEq(resting, 0);
        assertEq(book.orderInfo(bobAsk).qty, 0);
        assertFalse(book.orderInfo(bobAsk).open);
        assertEq(book.orderInfo(aliceAsk).qty, 1);
        assertTrue(book.orderInfo(aliceAsk).open);
        assertEq(book.lockedCash(ALICE), 600_000);
        assertEq(book.lockedCash(BOB), 0);
        assertEq(book.pool(series), 4 * UNIT);

        IMontionsBook.TradeView[] memory trades = book.recentTrades(series, 2);
        assertEq(trades.length, 2);
        assertEq(trades[0].tick, 40);
        assertEq(trades[0].qty, 2);
        assertEq(trades[1].tick, 35);
        assertEq(trades[1].qty, 2);
        assertEq(book.lastTradeTick(series), 40);
        assertEq(book.volumeOf(series), 4);
    }

    function testSameTickQueueIsFifo() public {
        _deposit(ALICE, 2_000_000);
        _deposit(BOB, 2_000_000);
        _deposit(CAROL, 1_000_000);
        (uint64 first,,) = _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        (uint64 second,,) = _place(BOB, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);

        (uint64 takerId,,) = _place(CAROL, IMontionsBook.Side.Bid, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(takerId, 3);
        assertFalse(book.orderInfo(first).open);
        assertTrue(book.orderInfo(second).open);
        assertEq(book.orderInfo(second).qty, 1);
    }

    function testSelfTradeCancelsRestingOrderAndThenRestsTaker() public {
        _deposit(ALICE, 2_000_000);
        (uint64 ask,,) = _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        (uint64 bid, uint64 filled, uint64 resting) =
            _place(ALICE, IMontionsBook.Side.Bid, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, 0);
        assertEq(resting, 1);
        assertFalse(book.orderInfo(ask).open);
        assertTrue(book.orderInfo(bid).open);
        assertEq(book.pool(series), 0);
        assertEq(book.lockedCash(ALICE), 400_000);
    }

    function testPostOnlyRevertsOnCrossWithoutChangingFundsOrOrderCount() public {
        _deposit(ALICE, 2_000_000);
        _deposit(BOB, 2_000_000);
        _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        uint256 beforeCash = book.cash(BOB);
        vm.expectRevert(IMontionsBook.WouldCross.selector);
        vm.prank(BOB);
        book.placeOrder(_params(series, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.POST_ONLY, 0));
        assertEq(book.cash(BOB), beforeCash);
        assertEq(book.orderCount(), 1);
    }

    function testIOCRefundsUnfilledRemainder() public {
        _deposit(ALICE, 2_000_000);
        _deposit(BOB, 1_000_000);
        _place(ALICE, IMontionsBook.Side.Ask, 40, 2, false, IMontionsBook.TIF.GTC, 0);
        (uint64 taker,, uint64 resting) = _place(BOB, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.IOC, 0);
        assertEq(resting, 0);
        assertFalse(book.orderInfo(taker).open);
        assertEq(book.orderInfo(taker).qty, 0);
        assertEq(book.cash(BOB), 600_000);
        assertEq(book.lockedCash(BOB), 0);
    }

    function testMaxFillsRefundsStillCrossingGTCRemainder() public {
        _deposit(ALICE, 5_000_000);
        _deposit(BOB, 2_000_000);
        _place(ALICE, IMontionsBook.Side.Ask, 30, 1, false, IMontionsBook.TIF.GTC, 0);
        _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        _place(ALICE, IMontionsBook.Side.Ask, 50, 1, false, IMontionsBook.TIF.GTC, 0);

        (uint64 id, uint64 filled, uint64 resting) =
            _place(BOB, IMontionsBook.Side.Bid, 60, 3, false, IMontionsBook.TIF.GTC, 1);
        assertEq(filled, 1);
        assertEq(resting, 0);
        assertFalse(book.orderInfo(id).open);
        assertEq(book.cash(BOB), 1_700_000);
        (uint8 bid,, uint8 ask,) = book.bestBidAsk(series);
        assertEq(bid, 0);
        assertEq(ask, 40);
    }

    function testDefaultMaxFillsIsThirtyTwo() public {
        _deposit(ALICE, 20_000_000);
        _deposit(BOB, 20_000_000);
        for (uint256 i; i < 33; ++i) {
            _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        }
        (, uint64 filled, uint64 resting) = _place(BOB, IMontionsBook.Side.Bid, 40, 33, false, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, 32);
        assertEq(resting, 0);
        assertEq(book.pool(series), 32 * UNIT);
        (,, uint8 bestAsk,) = book.bestBidAsk(series);
        assertEq(bestAsk, 40);
    }

    function testHeldAskMovesTokensAndCashWithoutChangingPool() public {
        _deposit(ALICE, 3 * UNIT);
        _deposit(BOB, UNIT);
        vm.prank(ALICE);
        book.split(series, 2);
        uint256 initialPool = book.pool(series);
        (uint64 id,,) = _place(ALICE, IMontionsBook.Side.Ask, 40, 2, true, IMontionsBook.TIF.GTC, 0);
        (, uint64 filled,) = _place(BOB, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.GTC, 0);

        assertEq(filled, 1);
        assertEq(book.pool(series), initialPool);
        assertEq(book.balanceOf(BOB, _yesId()), 1);
        assertEq(book.balanceOf(address(book), _yesId()), 1);
        assertEq(book.cash(ALICE), UNIT + 400_000);
        assertEq(book.lockedCash(ALICE), 0);
        assertEq(book.orderInfo(id).qty, 1);
        vm.prank(ALICE);
        book.cancelOrder(id);
        assertEq(book.balanceOf(ALICE, _yesId()), 1);
        assertEq(book.balanceOf(address(book), _yesId()), 0);
    }

    function testAskTakerWriteAtBidMakerPriceAndRefundsLimitDifference() public {
        _deposit(ALICE, 2_000_000);
        _deposit(BOB, 2_000_000);
        _place(BOB, IMontionsBook.Side.Bid, 60, 1, false, IMontionsBook.TIF.GTC, 0);
        (, uint64 filled,) = _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, 1);
        assertEq(book.pool(series), UNIT);
        assertEq(book.balanceOf(BOB, _yesId()), 1);
        assertEq(book.balanceOf(ALICE, _noId()), 1);
        assertEq(book.cash(ALICE), 1_600_000);
        assertEq(book.lockedCash(ALICE), 0);
        assertEq(book.lockedCash(BOB), 0);
    }

    function testCancelRefundsBidWriteAskAndHeldAsk() public {
        _deposit(ALICE, 3_000_000);
        (uint64 bid,,) = _place(ALICE, IMontionsBook.Side.Bid, 30, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(book.lockedCash(ALICE), 300_000);
        vm.prank(ALICE);
        book.cancelOrder(bid);
        assertEq(book.lockedCash(ALICE), 0);

        (uint64 ask,,) = _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(book.lockedCash(ALICE), 600_000);
        vm.prank(ALICE);
        book.cancelOrder(ask);
        assertEq(book.cash(ALICE), 3_000_000);

        vm.prank(ALICE);
        book.split(series, 1);
        (uint64 held,,) = _place(ALICE, IMontionsBook.Side.Ask, 60, 1, true, IMontionsBook.TIF.GTC, 0);
        vm.prank(ALICE);
        book.cancelOrder(held);
        assertEq(book.balanceOf(ALICE, _yesId()), 1);
        assertEq(book.lockedCash(ALICE), 0);
    }

    function testCancelOrdersCancelsSeveralOpenOrdersAtomically() public {
        _deposit(ALICE, 3_000_000);
        (uint64 first,,) = _place(ALICE, IMontionsBook.Side.Bid, 20, 1, false, IMontionsBook.TIF.GTC, 0);
        (uint64 second,,) = _place(ALICE, IMontionsBook.Side.Bid, 30, 1, false, IMontionsBook.TIF.GTC, 0);
        uint64[] memory ids = new uint64[](2);
        ids[0] = first;
        ids[1] = second;
        vm.prank(ALICE);
        book.cancelOrders(ids);
        assertEq(book.lockedCash(ALICE), 0);
        assertEq(book.cash(ALICE), 3_000_000);
        assertFalse(book.orderInfo(first).open);
        assertFalse(book.orderInfo(second).open);

        (uint64 third,,) = _place(ALICE, IMontionsBook.Side.Bid, 20, 1, false, IMontionsBook.TIF.GTC, 0);
        (uint64 fourth,,) = _place(ALICE, IMontionsBook.Side.Bid, 30, 1, false, IMontionsBook.TIF.GTC, 0);
        uint64[] memory invalid = new uint64[](2);
        invalid[0] = third;
        invalid[1] = 999;
        vm.expectRevert(IMontionsBook.OrderNotOpen.selector);
        vm.prank(ALICE);
        book.cancelOrders(invalid);
        assertTrue(book.orderInfo(third).open);
        assertTrue(book.orderInfo(fourth).open);
        assertEq(book.lockedCash(ALICE), 500_000);
    }

    function testSplitAndMergeBeforeAndAfterExpiry() public {
        _deposit(ALICE, 3 * UNIT);
        vm.prank(ALICE);
        book.split(series, 2);
        assertEq(book.pool(series), 2 * UNIT);
        assertEq(book.totalSupply(_yesId()), 2);
        assertEq(book.totalSupply(_noId()), 2);

        vm.prank(ALICE);
        book.merge(series, 1);
        assertEq(book.pool(series), UNIT);
        assertEq(book.cash(ALICE), 2 * UNIT);
        _warpExpired();
        vm.prank(ALICE);
        book.merge(series, 1);
        assertEq(book.pool(series), 0);
        assertEq(book.totalSupply(_yesId()), 0);
        vm.expectRevert(IMontionsBook.Expired.selector);
        vm.prank(ALICE);
        book.split(series, 1);
    }

    function testTradingExpiresButCancelStillWorks() public {
        _deposit(ALICE, 2_000_000);
        (uint64 id,,) = _place(ALICE, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.GTC, 0);
        _warpExpired();
        vm.expectRevert(IMontionsBook.Expired.selector);
        vm.prank(BOB);
        book.placeOrder(_params(series, IMontionsBook.Side.Ask, 50, 1, false, IMontionsBook.TIF.GTC, 0));
        vm.prank(ALICE);
        book.cancelOrder(id);
        assertEq(book.lockedCash(ALICE), 0);
    }

    function testResolveRedeemWinningAndLosingTokens() public {
        _deposit(ALICE, 2 * UNIT);
        vm.prank(ALICE);
        book.split(series, 2);
        resolver.setResult(true, true);
        vm.warp(uint256(expiry) + 1);
        book.resolve(series);
        assertEq(uint256(book.seriesInfo(series).status), uint256(IMontionsBook.Status.Resolved));

        vm.prank(ALICE);
        uint256 payout = book.redeem(series, 1, 1);
        assertEq(payout, UNIT);
        assertEq(book.pool(series), UNIT);
        assertEq(book.totalSupply(_yesId()), 1);
        vm.prank(ALICE);
        assertEq(book.redeem(series, 0, 1), 0);
        assertEq(book.pool(series), UNIT);
        vm.prank(ALICE);
        assertEq(book.redeem(series, 1, 0), UNIT);
        assertEq(book.pool(series), 0);
        vm.expectRevert(IMontionsBook.SeriesNotOpen.selector);
        vm.prank(ALICE);
        book.merge(series, 1);
    }

    function testNotReadyAndRevertingResolverVoidOnlyAfterGrace() public {
        _deposit(ALICE, 2 * UNIT);
        vm.prank(ALICE);
        book.split(series, 2);
        resolver.setResult(false, false);
        vm.expectRevert(IMontionsBook.NotExpired.selector);
        book.resolve(series);
        _warpExpired();
        vm.expectRevert(IMontionsBook.NotExpired.selector);
        book.resolve(series);

        resolver.setReverts(false, true);
        vm.warp(uint256(expiry) + book.VOID_GRACE() - 1);
        vm.expectRevert(IMontionsBook.NotExpired.selector);
        book.resolve(series);

        vm.warp(uint256(expiry) + book.VOID_GRACE());
        book.resolve(series);
        assertEq(uint256(book.seriesInfo(series).status), uint256(IMontionsBook.Status.Void));
        vm.prank(ALICE);
        uint256 payout = book.redeem(series, 1, 0);
        assertEq(payout, UNIT / 2);
        assertEq(book.pool(series) * 2, (book.totalSupply(_yesId()) + book.totalSupply(_noId())) * UNIT);
    }

    function testResolveUsesGasCappedStaticcall() public {
        resolver.setConsumeGas(true);
        _warpVoidable();
        book.resolve(series);
        assertEq(uint256(book.seriesInfo(series).status), uint256(IMontionsBook.Status.Void));
    }

    function testFeeIsCeiledAndOnlyChargedToTaker() public {
        _deposit(ALICE, 2_000_000);
        _deposit(BOB, 1_000_000);
        vm.prank(BOOK_OWNER);
        book.setFee(1, DAVE);
        _place(ALICE, IMontionsBook.Side.Ask, 1, 1, false, IMontionsBook.TIF.GTC, 0);
        _place(BOB, IMontionsBook.Side.Bid, 1, 1, false, IMontionsBook.TIF.GTC, 0);

        assertEq(book.protocolFees(), 1);
        assertEq(book.cash(ALICE), 1_010_000);
        assertEq(book.cash(BOB), 989_999);
        uint256 before = usdc.balanceOf(DAVE);
        vm.prank(CAROL);
        book.withdrawFees();
        assertEq(usdc.balanceOf(DAVE) - before, 1);
        assertEq(book.protocolFees(), 0);
    }

    function testFeeCapAndZeroRecipientValidation() public {
        vm.expectRevert(IMontionsBook.FeeTooHigh.selector);
        vm.prank(BOOK_OWNER);
        book.setFee(101, DAVE);
        vm.expectRevert(MontionsBook.BadFeeRecipient.selector);
        vm.prank(BOOK_OWNER);
        book.setFee(1, address(0));
    }

    function testDepthOrdersAndRingBufferViews() public {
        _deposit(ALICE, 8_000_000);
        _deposit(BOB, 8_000_000);
        _deposit(CAROL, 8_000_000);
        _place(ALICE, IMontionsBook.Side.Bid, 20, 2, false, IMontionsBook.TIF.GTC, 0);
        _place(ALICE, IMontionsBook.Side.Bid, 30, 1, false, IMontionsBook.TIF.GTC, 0);
        _place(BOB, IMontionsBook.Side.Ask, 50, 2, false, IMontionsBook.TIF.GTC, 0);
        (uint8 bid, uint64 bidQty, uint8 ask, uint64 askQty) = book.bestBidAsk(series);
        assertEq(bid, 30);
        assertEq(bidQty, 1);
        assertEq(ask, 50);
        assertEq(askQty, 2);

        IMontionsBook.Level[] memory levels = book.depth(series, IMontionsBook.Side.Bid, 2);
        assertEq(levels.length, 2);
        assertEq(levels[0].tick, 30);
        assertEq(levels[1].tick, 20);
        levels = book.depth(series, IMontionsBook.Side.Ask, 1);
        assertEq(levels.length, 1);
        assertEq(levels[0].tick, 50);

        (uint64 newest,,) = _place(ALICE, IMontionsBook.Side.Bid, 10, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(book.userOrderCount(ALICE), 3);
        IMontionsBook.OrderView[] memory orders = book.ordersOf(ALICE, 0, 2);
        assertEq(orders.length, 2);
        assertEq(orders[0].id, newest);
        assertEq(orders[1].id, 2);
        assertEq(book.orderInfo(newest).maker, ALICE);
        assertEq(book.ordersOf(ALICE, 99, 2).length, 0);
    }

    function testDepthAggregatesMultipleOrdersAtOneTick() public {
        _deposit(ALICE, 4_000_000);
        _deposit(BOB, 4_000_000);
        _place(ALICE, IMontionsBook.Side.Bid, 25, 2, false, IMontionsBook.TIF.GTC, 0);
        _place(BOB, IMontionsBook.Side.Bid, 25, 3, false, IMontionsBook.TIF.GTC, 0);
        IMontionsBook.Level[] memory levels = book.depth(series, IMontionsBook.Side.Bid, 99);
        assertEq(levels.length, 1);
        assertEq(levels[0].tick, 25);
        assertEq(levels[0].qty, 5);
        (, uint64 bestQty,,) = book.bestBidAsk(series);
        assertEq(bestQty, 5);
    }

    function testRecentTradeRingRetainsNewestSixtyFour() public {
        _deposit(ALICE, 100 * UNIT);
        _deposit(BOB, 100 * UNIT);
        for (uint256 i; i < 65; ++i) {
            _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        }
        _place(BOB, IMontionsBook.Side.Bid, 40, 65, false, IMontionsBook.TIF.GTC, 65);
        IMontionsBook.TradeView[] memory trades = book.recentTrades(series, 255);
        assertEq(trades.length, 64);
        assertEq(trades[0].ts, block.timestamp);
        assertEq(book.volumeOf(series), 65);
    }

    function testERC1155ApprovalsAndUserReceiverHooks() public {
        _deposit(ALICE, 2 * UNIT);
        vm.prank(ALICE);
        book.split(series, 2);
        OutcomeReceiver accepted = new OutcomeReceiver(false);
        OutcomeReceiver rejected = new OutcomeReceiver(true);
        uint256 yesId = _yesId();
        uint256 noId = _noId();

        vm.prank(ALICE);
        book.safeTransferFrom(ALICE, address(accepted), yesId, 1, "ok");
        assertEq(book.balanceOf(address(accepted), yesId), 1);
        vm.expectRevert(OutcomeReceiver.Rejected.selector);
        vm.prank(ALICE);
        book.safeTransferFrom(ALICE, address(rejected), yesId, 1, "no");
        assertEq(book.balanceOf(ALICE, yesId), 1);

        vm.prank(ALICE);
        book.setApprovalForAll(BOB, true);
        assertTrue(book.isApprovedForAll(ALICE, BOB));
        vm.expectRevert(MontionsBook.NotAuthorized.selector);
        vm.prank(ALICE);
        book.setApprovalForAll(ALICE, true);
        vm.prank(BOB);
        book.safeTransferFrom(ALICE, address(accepted), noId, 1, "approved");
        assertEq(book.balanceOf(address(accepted), noId), 1);

        vm.prank(ALICE);
        book.safeTransferFrom(ALICE, ALICE, yesId, 1, "self");
        assertEq(book.balanceOf(ALICE, yesId), 1);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = yesId;
        ids[1] = noId;
        amounts[0] = 1;
        amounts[1] = 1;
        vm.prank(ALICE);
        book.safeBatchTransferFrom(ALICE, address(accepted), ids, amounts, "batch");
        address[] memory accounts = new address[](2);
        accounts[0] = address(accepted);
        accounts[1] = address(accepted);
        uint256[] memory batchBalances = book.balanceOfBatch(accounts, ids);
        assertEq(batchBalances[0], 2);
        assertEq(batchBalances[1], 2);
    }

    function testMatchingDoesNotCallMakerERC1155ReceiverHook() public {
        RejectingMaker maker = new RejectingMaker(book, usdc);
        usdc.mint(address(maker), 2_000_000);
        maker.deposit(2_000_000);
        _deposit(BOB, 1_000_000);
        maker.placeAsk(series, 40, 1);
        (, uint64 filled,) = _place(BOB, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, 1);
        assertEq(book.balanceOf(address(maker), _noId()), 1);
    }

    function testOwnerCannotCancelOrWithdrawAnotherUsersAssets() public {
        _deposit(ALICE, UNIT);
        (uint64 orderId,,) = _place(ALICE, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.GTC, 0);
        vm.expectRevert(IMontionsBook.NotOrderOwner.selector);
        vm.prank(BOOK_OWNER);
        book.cancelOrder(orderId);
        assertEq(book.lockedCash(ALICE), 500_000);
        assertEq(book.cash(ALICE), 500_000);
        vm.prank(BOOK_OWNER);
        book.withdraw(0);
        assertEq(book.lockedCash(ALICE), 500_000);
    }

    function testCloseNoBidTakerMatchesWriteAsk() public {
        _deposit(ALICE, 3 * UNIT);
        _deposit(BOB, UNIT);
        vm.prank(ALICE);
        book.split(series, 2);
        _place(BOB, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);

        (, uint64 filled,) = _place(ALICE, IMontionsBook.Side.Bid, 50, 1, true, IMontionsBook.TIF.IOC, 0);
        assertEq(filled, 1);
        assertEq(book.cash(ALICE), 1_600_000);
        assertEq(book.lockedCash(ALICE), 0);
        assertEq(book.balanceOf(ALICE, _noId()), 1);
        assertEq(book.balanceOf(BOB, _noId()), 1);
        assertEq(book.pool(series), 2 * UNIT);
        assertEq(book.totalSupply(_yesId()), 2);
        assertEq(book.totalSupply(_noId()), 2);
        _assertSolvent();
    }

    function testCloseNoBidTakerMatchesHeldAsk() public {
        _deposit(ALICE, 2 * UNIT);
        _deposit(BOB, 2 * UNIT);
        vm.prank(ALICE);
        book.split(series, 1);
        vm.prank(BOB);
        book.split(series, 1);
        _place(BOB, IMontionsBook.Side.Ask, 40, 1, true, IMontionsBook.TIF.GTC, 0);

        (, uint64 filled,) = _place(ALICE, IMontionsBook.Side.Bid, 50, 1, true, IMontionsBook.TIF.IOC, 0);
        assertEq(filled, 1);
        assertEq(book.cash(ALICE), 1_600_000);
        assertEq(book.cash(BOB), 1_400_000);
        assertEq(book.pool(series), UNIT);
        assertEq(book.totalSupply(_yesId()), 1);
        assertEq(book.totalSupply(_noId()), 1);
        _assertSolvent();
    }

    function testCancelRestingCloseNoBidRefundsCashAndNO() public {
        _deposit(ALICE, 2 * UNIT);
        vm.prank(ALICE);
        book.split(series, 1);
        (uint64 id,,) = _place(ALICE, IMontionsBook.Side.Bid, 50, 1, true, IMontionsBook.TIF.GTC, 0);
        assertEq(book.balanceOf(ALICE, _noId()), 0);
        assertEq(book.balanceOf(address(book), _noId()), 1);
        assertEq(book.lockedCash(ALICE), 500_000);

        vm.prank(ALICE);
        book.cancelOrder(id);
        assertEq(book.balanceOf(ALICE, _noId()), 1);
        assertEq(book.balanceOf(address(book), _noId()), 0);
        assertEq(book.lockedCash(ALICE), 0);
        assertEq(book.cash(ALICE), UNIT);
        _assertSolvent();
    }

    function testRestingCloseNoBidMatchesWriteAskTaker() public {
        _deposit(ALICE, 2 * UNIT);
        _deposit(BOB, 2 * UNIT);
        vm.prank(ALICE);
        book.split(series, 1);
        _place(ALICE, IMontionsBook.Side.Bid, 50, 1, true, IMontionsBook.TIF.GTC, 0);

        (, uint64 filled,) = _place(BOB, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, 1);
        assertEq(book.cash(ALICE), 1_500_000);
        assertEq(book.cash(BOB), 1_500_000);
        assertEq(book.balanceOf(BOB, _noId()), 1);
        assertEq(book.pool(series), UNIT);
        assertEq(book.totalSupply(_yesId()), 1);
        assertEq(book.totalSupply(_noId()), 1);
        _assertSolvent();
    }

    function testRestingCloseNoBidMatchesHeldAskTaker() public {
        _deposit(ALICE, 2 * UNIT);
        _deposit(BOB, 2 * UNIT);
        vm.prank(ALICE);
        book.split(series, 1);
        vm.prank(BOB);
        book.split(series, 1);
        _place(ALICE, IMontionsBook.Side.Bid, 50, 1, true, IMontionsBook.TIF.GTC, 0);

        (, uint64 filled,) = _place(BOB, IMontionsBook.Side.Ask, 40, 1, true, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, 1);
        assertEq(book.cash(ALICE), 1_500_000);
        assertEq(book.cash(BOB), 1_500_000);
        assertEq(book.pool(series), UNIT);
        assertEq(book.totalSupply(_yesId()), 1);
        assertEq(book.totalSupply(_noId()), 1);
        _assertSolvent();
    }

    function testWriteAskFeeUsesWriterCollateralAndExactReserveCash() public {
        _deposit(BOB, UNIT);
        _deposit(ALICE, 10_100);
        vm.prank(BOOK_OWNER);
        book.setFee(100, DAVE);
        _place(BOB, IMontionsBook.Side.Bid, 99, 1, false, IMontionsBook.TIF.GTC, 0);

        (, uint64 filled,) = _place(ALICE, IMontionsBook.Side.Ask, 99, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, 1);
        assertEq(book.cash(ALICE), 0);
        assertEq(book.lockedCash(ALICE), 0);
        assertEq(book.protocolFees(), 100);
        assertEq(book.pool(series), UNIT);
        _assertSolvent();
    }

    function testBidCanFillWithOnlyEscrowPlusFeeReserveCash() public {
        _deposit(BOB, 10_100);
        _deposit(ALICE, 999_900);
        vm.prank(BOOK_OWNER);
        book.setFee(100, DAVE);
        _place(BOB, IMontionsBook.Side.Ask, 99, 1, false, IMontionsBook.TIF.GTC, 0);

        (, uint64 filled,) = _place(ALICE, IMontionsBook.Side.Bid, 99, 1, false, IMontionsBook.TIF.IOC, 0);
        assertEq(filled, 1);
        assertEq(book.cash(ALICE), 0);
        assertEq(book.lockedCash(ALICE), 0);
        assertEq(book.protocolFees(), 9_900);
        assertEq(book.pool(series), UNIT);
        _assertSolvent();
    }

    function testRestingWriteAskDoesNotKeepFeeReserve() public {
        _deposit(ALICE, 10_100);
        vm.prank(BOOK_OWNER);
        book.setFee(100, DAVE);
        (uint64 id,, uint64 resting) = _place(ALICE, IMontionsBook.Side.Ask, 99, 1, false, IMontionsBook.TIF.GTC, 0);
        assertEq(resting, 1);
        assertEq(book.lockedCash(ALICE), 10_000);
        assertEq(book.cash(ALICE), 100);
        vm.prank(ALICE);
        book.cancelOrder(id);
        assertEq(book.lockedCash(ALICE), 0);
        assertEq(book.cash(ALICE), 10_100);
    }

    function testFromHeldCloseNoFeeIsDeductedFromSaleProceeds() public {
        _deposit(ALICE, 1_500_000);
        _deposit(BOB, UNIT);
        vm.prank(BOOK_OWNER);
        book.setFee(100, DAVE);
        vm.prank(ALICE);
        book.split(series, 1);
        _place(BOB, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);

        (, uint64 filled,) = _place(ALICE, IMontionsBook.Side.Bid, 50, 1, true, IMontionsBook.TIF.IOC, 0);
        assertEq(filled, 1);
        assertEq(book.cash(ALICE), 1_094_000);
        assertEq(book.protocolFees(), 6_000);
        _assertSolvent();
    }

    function testCreateSeriesRejectsDataOver512Bytes() public {
        bytes memory data = new bytes(513);
        vm.expectRevert(abi.encodeWithSelector(MontionsBook.DataTooLong.selector, uint256(513)));
        vm.prank(ALICE);
        book.createSeries(address(resolver), data, expiry + 1);
    }

    function testOrderQuantityAndMaxFillsBounds() public {
        _deposit(ALICE, UNIT * 100);
        vm.expectRevert(IMontionsBook.BadQty.selector);
        vm.prank(ALICE);
        book.placeOrder(_params(series, IMontionsBook.Side.Bid, 50, uint64(1 << 40), false, IMontionsBook.TIF.GTC, 0));

        vm.expectRevert(abi.encodeWithSelector(MontionsBook.MaxFillsTooHigh.selector, uint16(257)));
        vm.prank(ALICE);
        book.placeOrder(_params(series, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.GTC, 257));
    }

    function testSplitAndMergeEnforceMaximumQuantityBeforeBalances() public {
        uint64 tooMany = uint64(1 << 40);

        vm.expectRevert(IMontionsBook.BadQty.selector);
        vm.prank(ALICE);
        book.split(series, tooMany);

        vm.expectRevert(IMontionsBook.BadQty.selector);
        vm.prank(ALICE);
        book.merge(series, tooMany);
    }

    function testResolveRequiresTimestampStrictlyAfterExpiry() public {
        resolver.setResult(true, true);
        vm.warp(expiry);
        vm.expectRevert(IMontionsBook.NotExpired.selector);
        book.resolve(series);
        vm.warp(uint256(expiry) + 1);
        book.resolve(series);
        assertEq(uint256(book.seriesInfo(series).status), uint256(IMontionsBook.Status.Resolved));
    }

    function testDepositRejectsFeeOnTransferCollateral() public {
        FeeOnTransferCollateral token = new FeeOnTransferCollateral();
        MontionsBook feeBook = new MontionsBook(address(token), BOOK_OWNER);
        token.mint(ALICE, 100);
        vm.prank(ALICE);
        token.approve(address(feeBook), 100);
        vm.expectRevert(
            abi.encodeWithSelector(MontionsBook.CollateralTransferMismatch.selector, uint256(100), uint256(99))
        );
        vm.prank(ALICE);
        feeBook.deposit(100);
    }

    function testFuzzWriteAskMatchingConservesPool(uint8 askTickSeed, uint8 spreadSeed, uint8 qtySeed) public {
        uint8 askTick = uint8(uint256(askTickSeed) % 99 + 1);
        uint8 spread = uint8(uint256(spreadSeed) % (100 - askTick));
        uint8 bidTick = askTick + spread;
        if (bidTick > 99) bidTick = 99;
        uint64 qty = uint64(uint256(qtySeed) % 10 + 1);
        _deposit(ALICE, UNIT * 100);
        _deposit(BOB, UNIT * 100);
        _place(ALICE, IMontionsBook.Side.Ask, askTick, qty, false, IMontionsBook.TIF.GTC, 0);
        (, uint64 filled,) = _place(BOB, IMontionsBook.Side.Bid, bidTick, qty, false, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, qty);
        assertEq(book.pool(series), uint256(qty) * UNIT);
        assertEq(book.totalSupply(_yesId()), qty);
        assertEq(book.totalSupply(_noId()), qty);
        _assertSolvent();
    }

    function testFuzzWriteTakerMatchesBidMaker(uint8 bidSeed, uint8 askSpreadSeed, uint8 qtySeed) public {
        uint8 bidTick = uint8(uint256(bidSeed) % 99 + 1);
        uint8 spread = uint8(uint256(askSpreadSeed) % bidTick);
        uint8 askTick = bidTick - spread;
        uint64 qty = uint64(uint256(qtySeed) % 10 + 1);
        _deposit(ALICE, UNIT * 100);
        _deposit(BOB, UNIT * 100);
        _place(ALICE, IMontionsBook.Side.Bid, bidTick, qty, false, IMontionsBook.TIF.GTC, 0);
        (, uint64 filled,) = _place(BOB, IMontionsBook.Side.Ask, askTick, qty, false, IMontionsBook.TIF.GTC, 0);
        assertEq(filled, qty);
        assertEq(book.pool(series), uint256(qty) * UNIT);
        assertEq(book.totalSupply(_yesId()), qty);
        assertEq(book.totalSupply(_noId()), qty);
        _assertSolvent();
    }
}

contract OutcomeReceiver {
    error Rejected();
    bool private immutable _reject;

    constructor(bool reject_) {
        _reject = reject_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (_reject) revert Rejected();
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (_reject) revert Rejected();
        return 0xbc197c81;
    }
}

contract RejectingMaker {
    MontionsBook private immutable _book;
    TestUSDC private immutable _usdc;

    constructor(MontionsBook book_, TestUSDC usdc_) {
        _book = book_;
        _usdc = usdc_;
    }

    function deposit(uint256 amount) external {
        _usdc.approve(address(_book), amount);
        _book.deposit(amount);
    }

    function placeAsk(bytes32 seriesId, uint8 tick, uint64 qty) external {
        _book.placeOrder(
            IMontionsBook.PlaceParams({
                seriesId: seriesId,
                side: IMontionsBook.Side.Ask,
                tick: tick,
                qty: qty,
                fromHeld: false,
                tif: IMontionsBook.TIF.GTC,
                maxFills: 0
            })
        );
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("hook must not run during fill");
    }
}

contract FeeOnTransferCollateral {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        require(approved >= amount && balanceOf[from] >= amount);
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1;
        return true;
    }
}
