// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultTestBase} from "./VaultTestBase.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {MakerVault} from "../../src/MakerVault.sol";
import {MockResolver} from "../book/mocks/MockResolver.sol";
import {ReentrantBook} from "./mocks/ReentrantBook.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

contract MakerVaultTest is VaultTestBase {
    function testMetadataAndConstructor() public view {
        assertEq(vault.name(), "Montions Maker Vault");
        assertEq(vault.symbol(), "mmUSDC");
        assertEq(vault.decimals(), 6);
        assertEq(vault.asset(), address(usdc));
        assertEq(address(vault.book()), address(book));
        assertEq(address(vault.quoter()), address(quoter));
        assertEq(vault.owner(), address(this));
        assertEq(vault.keeper(), KEEPER);
        assertEq(vault.maxSeriesExposureBps(), 1_000);
        assertEq(vault.maxGlobalExposureBps(), 3_000);
        assertEq(vault.minFreeCashBps(), 2_000);
    }

    function testConstructorRejectsZero() public {
        vm.expectRevert(MakerVault.ZeroAddress.selector);
        new MakerVault(address(0), address(quoter), address(this));
        vm.expectRevert(MakerVault.ZeroAddress.selector);
        new MakerVault(address(book), address(0), address(this));
        vm.expectRevert(MakerVault.ZeroAddress.selector);
        new MakerVault(address(book), address(quoter), address(0));
    }

    // ───────────────────────── deposit / withdraw / shares ─────────────────────────

    function testFirstDepositorShareMath() public {
        uint256 assets = 1_000e6;
        uint256 shares = _depositVault(ALICE, assets);
        // virtual offset 6: shares = assets * 1e6 / 1
        assertEq(shares, assets * 1e6);
        assertEq(vault.balanceOf(ALICE), shares);
        assertEq(vault.totalAssets(), assets);
        assertEq(book.cash(address(vault)), assets);
        assertEq(usdc.balanceOf(address(vault)), 0);

        uint256 preview = vault.previewRedeem(shares);
        assertApproxEqAbs(preview, assets, 1);

        vm.prank(ALICE);
        uint256 out = vault.redeem(shares, ALICE, ALICE);
        assertApproxEqAbs(out, assets, 1);
        assertEq(vault.totalSupply(), 0);
    }

    function testDepositWithdrawRoundTrip() public {
        uint256 shares = _depositVault(ALICE, 5_000e6);
        _depositVault(BOB, 2_500e6);
        assertEq(vault.totalAssets(), 7_500e6);

        uint256 aliceAssets = vault.convertToAssets(shares);
        uint256 half = aliceAssets / 2;
        uint256 expectShares = vault.previewWithdraw(half);
        vm.prank(ALICE);
        uint256 burned = vault.withdraw(half, ALICE, ALICE);
        assertEq(burned, expectShares);
        assertEq(usdc.balanceOf(ALICE), 1_000_000e6 - 5_000e6 + half);
    }

    function testMintAndRedeem() public {
        uint256 wantShares = 1_000e6 * 1e6;
        vm.prank(ALICE);
        uint256 assets = vault.mint(wantShares, ALICE);
        assertEq(assets, 1_000e6);
        assertEq(vault.balanceOf(ALICE), wantShares);

        vm.prank(ALICE);
        uint256 out = vault.redeem(wantShares / 2, BOB, ALICE);
        assertGt(out, 0);
        assertEq(usdc.balanceOf(BOB), 1_000_000e6 + out);
    }

    function testWithdrawViaAllowance() public {
        _depositVault(ALICE, 1_000e6);
        uint256 assets = 100e6;
        uint256 shares = vault.previewWithdraw(assets);
        vm.prank(ALICE);
        vault.approve(BOB, shares);
        vm.prank(BOB);
        vault.withdraw(assets, BOB, ALICE);
        assertEq(usdc.balanceOf(BOB), 1_000_000e6 + assets);
    }

    function testZeroDepositReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(MakerVault.ZeroAmount.selector);
        vault.deposit(0, ALICE);
    }

    function testInflationAttackDoesNotSteal() public {
        // Classic attack: 1 wei deposit + huge donation, victim should still receive shares.
        vm.prank(ATTACKER);
        uint256 attackerShares = vault.deposit(1, ATTACKER);
        assertGt(attackerShares, 0);

        vm.prank(ATTACKER);
        usdc.transfer(address(vault), 10_000e6);

        uint256 navBefore = vault.totalAssets();
        assertEq(navBefore, 1 + 10_000e6);

        vm.prank(BOB);
        uint256 victimShares = vault.deposit(1_000e6, BOB);
        assertGt(victimShares, 0, "virtual offset must mint shares for the victim");

        uint256 victimValue = vault.convertToAssets(victimShares);
        // Victim keeps nearly their deposit; attacker cannot round them to zero.
        assertGt(victimValue, 900e6);
        assertLt(victimValue, 1_100e6);

        uint256 attackerValue = vault.convertToAssets(attackerShares);
        // Attacker donated 10k and should not extract the victim's 1k.
        assertLt(attackerValue, 10_500e6);
    }

    function testConvertRoundTripFuzz(uint128 assetsRaw) public {
        uint256 assets = bound(assetsRaw, 1, 100_000e6);
        _depositVault(ALICE, 50_000e6);
        uint256 shares = vault.convertToShares(assets);
        uint256 back = vault.convertToAssets(shares);
        assertLe(back, assets);
    }

    // ───────────────────────── ladder ─────────────────────────

    function testHalfSpreadFormula() public view {
        assertEq(vault.halfSpread(0), 12);
        assertEq(vault.halfSpread(66), 12); // below 10 min, clamped
        assertEq(vault.halfSpread(10 minutes), 4);
        assertEq(vault.halfSpread(1 days), 2);
        assertEq(vault.halfSpread(90 days), 2);
        assertGe(vault.halfSpread(10 minutes), vault.halfSpread(1 hours));
    }

    function testLadderTicksFair50Spread2() public view {
        (uint8[] memory bids, uint8[] memory asks) = vault.ladderTicks(50, 2);
        assertEq(bids.length, 3);
        assertEq(asks.length, 3);
        assertEq(bids[0], 48);
        assertEq(bids[1], 46);
        assertEq(bids[2], 44);
        assertEq(asks[0], 52);
        assertEq(asks[1], 54);
        assertEq(asks[2], 56);
    }

    function testLadderTicksClampAndCollapse() public view {
        (uint8[] memory bids, uint8[] memory asks) = vault.ladderTicks(1, 2);
        // bids clamp to 1; 1 < asks 3, so one bid remains
        assertEq(bids.length, 1);
        assertEq(bids[0], 1);
        assertEq(asks[0], 3);
        assertEq(asks[1], 5);
        assertEq(asks[2], 7);

        (bids, asks) = vault.ladderTicks(99, 2);
        assertEq(asks.length, 1);
        assertEq(asks[0], 99);
        assertEq(bids[0], 97);
        assertEq(bids[1], 95);
        assertEq(bids[2], 93);
    }

    function testRefreshPostsExactTicksAndSizes() public {
        uint256 assets = 10_000e6;
        _depositVault(ALICE, assets);
        _refresh();

        IMontionsBook.OrderView[] memory open_ = _openOrders();
        assertEq(open_.length, 6);

        (uint8[] memory bids, uint8[] memory asks) = vault.ladderTicks(50, 2);
        uint256 weight = _tickWeight(bids, asks);
        assertEq(weight, 276);
        uint64 qty = _expectedQty(assets, weight);
        assertEq(qty, 362);

        uint8 nBid;
        uint8 nAsk;
        for (uint256 i; i < open_.length; ++i) {
            assertEq(open_[i].qty, qty);
            assertEq(open_[i].maker, address(vault));
            assertFalse(open_[i].fromHeld);
            if (open_[i].side == IMontionsBook.Side.Bid) {
                assertTrue(open_[i].tick == 48 || open_[i].tick == 46 || open_[i].tick == 44);
                ++nBid;
            } else {
                assertTrue(open_[i].tick == 52 || open_[i].tick == 54 || open_[i].tick == 56);
                ++nAsk;
            }
        }
        assertEq(nBid, 3);
        assertEq(nAsk, 3);
    }

    function testRefreshCancelsOldLadderFirst() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();
        uint64[] memory first = vault.trackedOrders(series);
        assertEq(first.length, 6);
        for (uint256 i; i < first.length; ++i) {
            assertTrue(book.orderInfo(first[i]).open);
        }

        quoter.setFair(series, 40);
        _refresh();
        uint64[] memory second = vault.trackedOrders(series);
        assertEq(second.length, 6);
        for (uint256 i; i < first.length; ++i) {
            assertFalse(book.orderInfo(first[i]).open);
        }
        (uint8[] memory bids, uint8[] memory asks) = vault.ladderTicks(40, 2);
        assertEq(bids[0], 38);
        assertEq(asks[0], 42);
        bool saw38;
        bool saw42;
        for (uint256 i; i < second.length; ++i) {
            IMontionsBook.OrderView memory ov = book.orderInfo(second[i]);
            assertTrue(ov.open);
            if (ov.tick == 38) saw38 = true;
            if (ov.tick == 42) saw42 = true;
        }
        assertTrue(saw38);
        assertTrue(saw42);
    }

    function testRefreshNearExpiryUsesWiderSpread() public {
        _depositVault(ALICE, 10_000e6);
        vm.warp(expiry - 10 minutes);
        _refresh();
        IMontionsBook.OrderView[] memory open_ = _openOrders();
        assertEq(open_.length, 6);
        assertEq(vault.halfSpread(10 minutes), 4);
        bool saw46;
        bool saw54;
        for (uint256 i; i < open_.length; ++i) {
            if (open_[i].tick == 46 && open_[i].side == IMontionsBook.Side.Bid) saw46 = true;
            if (open_[i].tick == 54 && open_[i].side == IMontionsBook.Side.Ask) saw54 = true;
        }
        assertTrue(saw46);
        assertTrue(saw54);
    }

    // ───────────────────────── stop-quoting ─────────────────────────

    function testStopQuotingBelowTenMinutes() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();
        assertEq(_openOrders().length, 6);

        vm.warp(expiry - 10 minutes + 1);
        _refresh();
        assertEq(_openOrders().length, 0);
        assertEq(vault.trackedOrders(series).length, 0);
    }

    function testStopQuotingWhenFairZero() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();
        quoter.setFair(series, 0);
        _refresh();
        assertEq(_openOrders().length, 0);
    }

    function testStopQuotingWhenNotOpen() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();
        resolver.setResult(true, true);
        vm.warp(uint256(expiry) + 1);
        book.resolve(series);
        _refresh();
        assertEq(_openOrders().length, 0);
    }

    function testStopQuotingWhenPaused() public {
        _depositVault(ALICE, 10_000e6);
        vault.setQuotingPaused(true);
        _refresh();
        assertEq(_openOrders().length, 0);

        vault.setQuotingPaused(false);
        _refresh();
        assertEq(_openOrders().length, 6);
    }

    // ───────────────────────── access control ─────────────────────────

    function testRefreshOnlyOwnerOrKeeper() public {
        _depositVault(ALICE, 10_000e6);
        vm.prank(ALICE);
        vm.expectRevert(MakerVault.NotKeeper.selector);
        vault.refresh(series);

        vm.prank(KEEPER);
        vault.refresh(series);
        assertEq(_openOrders().length, 6);

        // owner (this) may also refresh
        quoter.setFair(series, 55);
        vault.refresh(series);
        assertEq(_openOrders().length, 6);
    }

    function testOwnerCannotWithdrawUserFundsDirectly() public {
        _depositVault(ALICE, 1_000e6);
        // owner has no shares
        vm.expectRevert(MakerVault.WithdrawMoreThanMax.selector);
        vault.withdraw(1, address(this), address(this));
        assertEq(book.cash(address(vault)), 1_000e6);
    }

    function testSetCapsBounded() public {
        vault.setCaps(500, 1_500, 4_000);
        assertEq(vault.maxSeriesExposureBps(), 500);
        assertEq(vault.maxGlobalExposureBps(), 1_500);
        assertEq(vault.minFreeCashBps(), 4_000);

        vm.expectRevert(MakerVault.CapTooHigh.selector);
        vault.setCaps(1_001, 3_000, 2_000);
        vm.expectRevert(MakerVault.CapTooHigh.selector);
        vault.setCaps(1_000, 3_001, 2_000);
        vm.expectRevert(MakerVault.CapTooLow.selector);
        vault.setCaps(1_000, 3_000, 1_999);
        vm.expectRevert(MakerVault.CapTooHigh.selector);
        vault.setCaps(1_000, 3_000, 10_001);

        vm.prank(ALICE);
        vm.expectRevert(); // Ownable unauthorized
        vault.setCaps(1_000, 3_000, 2_000);
    }

    function testSetKeeperAndResolverOnlyOwner() public {
        vault.setKeeper(address(0));
        vm.prank(KEEPER);
        vm.expectRevert(MakerVault.NotKeeper.selector);
        vault.refresh(series);

        vault.setKeeper(KEEPER);
        vault.setTrustedResolver(address(0x1234));
        assertEq(vault.trustedResolver(), address(0x1234));
    }

    // ───────────────────────── caps ─────────────────────────

    function testSeriesExposureCapSizesLadder() public {
        _depositVault(ALICE, 10_000e6);
        vault.setCaps(500, 3_000, 2_000); // 5% series
        _refresh();
        IMontionsBook.OrderView[] memory open_ = _openOrders();
        uint64 qty = open_[0].qty;
        (uint8[] memory bids, uint8[] memory asks) = vault.ladderTicks(50, 2);
        uint64 expect = _expectedQty(10_000e6, _tickWeight(bids, asks));
        assertEq(qty, expect);
        assertLt(qty, 362); // tighter than the 10% default
    }

    function testFreeCashCapPreventsPosting() public {
        _depositVault(ALICE, 10_000e6);
        // Require 99% free cash after quoting → 1% room to lock.
        vault.setCaps(1_000, 3_000, 9_900);
        uint256 nav = vault.totalAssets();
        (uint8[] memory bids, uint8[] memory asks) = vault.ladderTicks(50, 2);
        uint64 q = _expectedQty(nav, _tickWeight(bids, asks));
        _refresh();
        IMontionsBook.OrderView[] memory open_ = _openOrders();
        if (q == 0) {
            assertEq(open_.length, 0);
        } else {
            assertEq(open_[0].qty, q);
            assertGe(book.cash(address(vault)) * 10_000, vault.totalAssets() * 9_900);
        }
        assertLe(book.lockedCash(address(vault)), nav / 100);
    }

    function testGlobalExposureCapBlocksFourthSeries() public {
        _depositVault(ALICE, 10_000e6);
        bytes32 s2 = _createSeries(bytes("s2"), expiry);
        bytes32 s3 = _createSeries(bytes("s3"), expiry);
        bytes32 s4 = _createSeries(bytes("s4"), expiry);
        quoter.setFair(s2, 50);
        quoter.setFair(s3, 50);
        quoter.setFair(s4, 50);

        vm.startPrank(KEEPER);
        vault.refresh(series);
        vault.refresh(s2);
        vault.refresh(s3);
        vault.refresh(s4);
        vm.stopPrank();

        // Three series at ~10% each fill the 30% global cap; the fourth should not post.
        uint256 open4;
        uint64[] memory ids = vault.trackedOrders(s4);
        for (uint256 i; i < ids.length; ++i) {
            if (book.orderInfo(ids[i]).open) ++open4;
        }
        assertEq(open4, 0);
        assertGt(vault.trackedOrders(series).length, 0);
        assertGt(vault.trackedOrders(s2).length, 0);
        assertGt(vault.trackedOrders(s3).length, 0);
    }

    function testSmallDepositDoesNotQuote() public {
        _depositVault(ALICE, 1e6); // 1 USDC, 10% = 0.1 USDC < 2.76 USDC per lot
        _refresh();
        assertEq(_openOrders().length, 0);
    }

    // ───────────────────────── withdraw cancels ─────────────────────────

    function testWithdrawCancelsOrdersToFreeCash() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();
        assertGt(book.lockedCash(address(vault)), 0);
        uint256 freeBefore = book.cash(address(vault));
        assertLt(freeBefore, 10_000e6);

        uint256 want = 9_500e6;
        vm.prank(ALICE);
        vault.withdraw(want, ALICE, ALICE);
        assertEq(usdc.balanceOf(ALICE), 1_000_000e6 - 10_000e6 + want);
        // Orders cancelled so cash could be freed.
        assertEq(_openOrders().length, 0);
    }

    function testWithdrawRevertsIfInventoryIlliquid() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();

        // Taker lifts the inner ask; vault receives NO inventory that cannot be cancelled into cash.
        vm.prank(TAKER);
        book.deposit(5_000e6);
        _placeTaker(TAKER, IMontionsBook.Side.Bid, 52, 362, false, IMontionsBook.TIF.GTC);

        uint256 yesId = book.seriesInfo(series).yesId;
        uint256 noId = book.seriesInfo(series).noId;
        assertGt(book.balanceOf(address(vault), noId), 0);
        assertGt(book.balanceOf(TAKER, yesId), 0);

        uint256 nav = vault.totalAssets();
        uint256 liquid = book.cash(address(vault)) + book.lockedCash(address(vault)) + usdc.balanceOf(address(vault));
        assertLt(liquid, nav); // inventory mark is not liquid

        vm.prank(ALICE);
        vm.expectRevert(MakerVault.InsufficientCash.selector);
        vault.withdraw(nav, ALICE, ALICE);
    }

    // ───────────────────────── taker vs real book ─────────────────────────

    function testTakerHitsVaultAskUpdatesNav() public {
        uint256 shares = _depositVault(ALICE, 10_000e6);
        _refresh();
        uint256 navBefore = vault.totalAssets();

        vm.prank(TAKER);
        book.deposit(5_000e6);
        (, uint64 filled,) = _placeTaker(TAKER, IMontionsBook.Side.Bid, 52, 10, false, IMontionsBook.TIF.IOC);
        assertEq(filled, 10);

        uint256 noId = book.seriesInfo(series).noId;
        assertEq(book.balanceOf(address(vault), noId), 10);

        uint256 navAfter = vault.totalAssets();
        // Conservative NO mark ≤ write collateral of 0.48 USDC/contract; NAV should not jump up.
        assertLe(navAfter, navBefore);
        // Share supply unchanged; NAV per share reflects the fill.
        assertEq(vault.totalSupply(), shares);
        assertEq(vault.convertToAssets(shares), navAfter);
        // Remaining asks + bids still tracked.
        assertGt(_openOrders().length, 0);
    }

    function testTakerHitsVaultBidGivesYesInventory() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();

        vm.prank(TAKER);
        book.deposit(5_000e6);
        vm.prank(TAKER);
        book.split(series, 20);

        (, uint64 filled,) = _placeTaker(TAKER, IMontionsBook.Side.Ask, 44, 5, true, IMontionsBook.TIF.IOC);
        assertEq(filled, 5);
        uint256 yesId = book.seriesInfo(series).yesId;
        assertEq(book.balanceOf(address(vault), yesId), 5);
    }

    function testFromHeldAskWhenVaultHoldsYes() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();

        vm.prank(TAKER);
        book.deposit(5_000e6);
        vm.prank(TAKER);
        book.split(series, 50);
        _placeTaker(TAKER, IMontionsBook.Side.Ask, 44, 20, true, IMontionsBook.TIF.IOC);

        assertEq(book.balanceOf(address(vault), book.seriesInfo(series).yesId), 20);

        _refresh();
        IMontionsBook.OrderView[] memory open_ = _openOrders();
        bool sawFromHeld;
        for (uint256 i; i < open_.length; ++i) {
            if (open_[i].side == IMontionsBook.Side.Ask && open_[i].fromHeld) {
                sawFromHeld = true;
                assertLe(open_[i].qty, 20);
            }
        }
        assertTrue(sawFromHeld);
    }

    // ───────────────────────── settlement ─────────────────────────

    function testRedeemSeriesResolvedYes() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();
        vm.prank(TAKER);
        book.deposit(5_000e6);
        _placeTaker(TAKER, IMontionsBook.Side.Bid, 52, 10, false, IMontionsBook.TIF.IOC);
        // Vault holds NO; YES wins → NO redeems to 0.
        resolver.setResult(true, true);
        vm.warp(uint256(expiry) + 1);
        book.resolve(series);

        uint256 navBefore = vault.totalAssets();
        uint256 payout = vault.redeemSeries(series);
        assertEq(payout, 0);
        assertLe(vault.totalAssets(), navBefore);
        assertEq(book.balanceOf(address(vault), book.seriesInfo(series).noId), 0);
    }

    function testRedeemSeriesResolvedNo() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();
        vm.prank(TAKER);
        book.deposit(5_000e6);
        _placeTaker(TAKER, IMontionsBook.Side.Bid, 52, 10, false, IMontionsBook.TIF.IOC);

        resolver.setResult(true, false);
        vm.warp(uint256(expiry) + 1);
        book.resolve(series);

        uint256 cashBefore = book.cash(address(vault));
        uint256 payout = vault.redeemSeries(series);
        assertEq(payout, 10 * UNIT);
        assertGt(book.cash(address(vault)), cashBefore + 10 * UNIT); // cancel unlocks resting escrow too
        assertEq(book.balanceOf(address(vault), book.seriesInfo(series).noId), 0);
        assertEq(vault.totalAssets(), book.cash(address(vault)) + book.lockedCash(address(vault)));
    }

    function testRedeemSeriesVoid() public {
        _depositVault(ALICE, 10_000e6);
        _refresh();
        vm.prank(TAKER);
        book.deposit(5_000e6);
        _placeTaker(TAKER, IMontionsBook.Side.Bid, 52, 8, false, IMontionsBook.TIF.IOC);

        resolver.setResult(false, false);
        vm.warp(uint256(expiry) + book.VOID_GRACE());
        book.resolve(series);
        assertEq(uint256(book.seriesInfo(series).status), uint256(IMontionsBook.Status.Void));

        uint256 payout = vault.redeemSeries(series);
        assertEq(payout, 8 * UNIT / 2);
    }

    function testRedeemSeriesRevertsIfOpen() public {
        vm.expectRevert(MakerVault.SeriesNotSettled.selector);
        vault.redeemSeries(series);
    }

    // ───────────────────────── adversarial ─────────────────────────

    function testForeignResolverIsIgnored() public {
        MockResolver foreign = new MockResolver();
        book.setResolverAllowed(address(foreign), true);
        bytes32 bad = book.createSeries(address(foreign), bytes("foreign"), expiry);
        quoter.setFair(bad, 50); // attacker tries to look like a price series

        _depositVault(ALICE, 10_000e6);
        vm.prank(KEEPER);
        vault.refresh(bad);

        uint64[] memory ids = vault.trackedOrders(bad);
        uint256 openN;
        for (uint256 i; i < ids.length; ++i) {
            if (book.orderInfo(ids[i]).open) ++openN;
        }
        assertEq(openN, 0);
        assertEq(book.userOrderCount(address(vault)), 0);
    }

    function testUnknownSeriesRefreshDoesNotRevert() public {
        vm.prank(KEEPER);
        vault.refresh(bytes32(uint256(0xdead)));
    }

    function testErc1155ReceiverAcceptsTokens() public {
        _depositVault(ALICE, 1_000e6);
        vm.prank(ALICE);
        book.deposit(10 * UNIT);
        vm.prank(ALICE);
        book.split(series, 10);
        uint256 yesId = book.seriesInfo(series).yesId;
        vm.prank(ALICE);
        book.safeTransferFrom(ALICE, address(vault), yesId, 3, "");
        assertEq(book.balanceOf(address(vault), yesId), 3);
        assertEq(
            vault.onERC1155Received(address(0), address(0), 0, 0, ""),
            vault.onERC1155Received.selector
        );
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amts = new uint256[](0);
        assertEq(
            vault.onERC1155BatchReceived(address(0), address(0), ids, amts, ""),
            vault.onERC1155BatchReceived.selector
        );
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertTrue(vault.supportsInterface(0x4e2312e0));
    }

    function testReentrancyOnDepositReverts() public {
        ReentrantBook rb = new ReentrantBook(address(usdc));
        MakerVault v = new MakerVault(address(rb), address(quoter), address(this));
        rb.setVault(v);
        usdc.mint(ALICE, 100e6);
        vm.prank(ALICE);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        v.deposit(50e6, ALICE);
    }

    function testPreviewMatchesDeposit() public {
        _depositVault(ALICE, 1_000e6);
        uint256 assets = 250e6;
        uint256 preview = vault.previewDeposit(assets);
        vm.prank(BOB);
        uint256 minted = vault.deposit(assets, BOB);
        assertEq(minted, preview);
    }
}

