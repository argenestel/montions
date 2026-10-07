// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Quoter} from "../../src/Quoter.sol";
import {IQuoter} from "../../src/interfaces/IQuoter.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {IResolver} from "../../src/interfaces/IResolver.sol";
import {TwapThresholdResolver} from "../../src/resolvers/TwapThresholdResolver.sol";
import {MockBook} from "./mocks/MockBook.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

contract QuoterSnapshotsTest is Test {
    MockBook internal book;
    MockPriceOracle internal oracle;
    TwapThresholdResolver internal resolver;
    Quoter internal quoter;
    bytes32 internal constant ASSET = keccak256("MON");

    function setUp() public {
        vm.warp(1_000_000);
        book = new MockBook();
        oracle = new MockPriceOracle();
        oracle.setAsset(ASSET, true);
        oracle.setPrice(ASSET, 1e18);
        resolver = new TwapThresholdResolver(address(oracle), address(this));
        resolver.setSymbol(ASSET, "MON");
        quoter = new Quoter(address(book), address(resolver));
        _series(bytes32(uint256(1)));
    }

    function _series(bytes32 id) internal {
        book.setSeries(
            id,
            address(resolver),
            abi.encode(address(oracle), ASSET, uint256(1e18), true, uint32(60)),
            1_003_600,
            IMontionsBook.Status.Open,
            false,
            123,
            456,
            1_000_000
        );
    }

    function testSnapshotBundlesAllFields() public {
        bytes32 id = bytes32(uint256(1));
        uint8[] memory ticks = new uint8[](1);
        uint64[] memory quantities = new uint64[](1);
        ticks[0] = 45;
        quantities[0] = 7;
        book.setDepth(id, IMontionsBook.Side.Bid, ticks, quantities);
        ticks[0] = 55;
        quantities[0] = 9;
        book.setDepth(id, IMontionsBook.Side.Ask, ticks, quantities);
        book.setLastTradeTick(id, 52);
        IQuoter.Snapshot memory s = quoter.snapshot(id);
        assertEq(s.seriesId, id);
        assertEq(s.info.resolver, address(resolver));
        assertEq(s.info.data, abi.encode(address(oracle), ASSET, uint256(1e18), true, uint32(60)));
        assertEq(s.info.expiry, 1_003_600);
        assertEq(uint256(s.info.status), uint256(IMontionsBook.Status.Open));
        assertFalse(s.info.yes);
        assertEq(s.info.yesId, 123);
        assertEq(s.info.noId, 456);
        assertEq(s.info.createdAt, 1_000_000);
        assertEq(s.bidTick, 45);
        assertEq(s.bidQty, 7);
        assertEq(s.askTick, 55);
        assertEq(s.askQty, 9);
        assertEq(s.lastTick, 52);
        (uint8 tick, uint256 prob, uint256 vol, uint256 spot) = quoter.fair(id);
        assertEq(s.fairTick, tick);
        assertEq(s.probWad, prob);
        assertEq(s.volWad, vol);
        assertEq(s.spotWad, spot);
        assertEq(spot, 1e18);
        assertEq(s.title, resolver.describe(s.info.data, s.info.expiry));
        assertGt(bytes(s.title).length, 0);
    }

    function testDescribeFailureReturnsEmptyTitleButRetainsModel() public {
        vm.mockCallRevert(address(resolver), abi.encodeWithSelector(IResolver.describe.selector), "failed");
        IQuoter.Snapshot memory s = quoter.snapshot(bytes32(uint256(1)));
        assertEq(s.title, "");
        assertGt(s.fairTick, 0);
    }

    function testSnapshotFailedViewsAndUnknownSeries() public {
        book.setReverts(true, true, false, true);
        IQuoter.Snapshot memory s = quoter.snapshot(bytes32(uint256(1)));
        assertEq(s.seriesId, bytes32(uint256(1)));
        assertEq(s.info.resolver, address(0));
        assertEq(s.bidTick, 0);
        assertEq(s.askTick, 0);
        assertEq(s.lastTick, 0);
        assertEq(s.title, "");
        assertEq(s.fairTick, 0);
        book.setReverts(false, false, false, false);
        s = quoter.snapshot(bytes32(uint256(999)));
        assertEq(s.seriesId, bytes32(uint256(999)));
        assertEq(s.fairTick, 0);
    }

    function testPagingCapOffsetTailAndHugeArguments() public {
        for (uint256 i = 2; i <= 56; ++i) {
            _series(bytes32(i));
        }
        IQuoter.Snapshot[] memory page = quoter.snapshots(0, type(uint256).max);
        assertEq(page.length, 50);
        for (uint256 i; i < page.length; ++i) {
            assertEq(page[i].seriesId, bytes32(i + 1));
        }
        page = quoter.snapshots(50, 50);
        assertEq(page.length, 6);
        for (uint256 i; i < page.length; ++i) {
            assertEq(page[i].seriesId, bytes32(i + 51));
        }
        assertEq(quoter.snapshots(56, 50).length, 0);
        assertEq(quoter.snapshots(type(uint256).max, type(uint256).max).length, 0);
        assertEq(quoter.snapshots(0, 0).length, 0);
        page = quoter.snapshots(2, 1);
        assertEq(page.length, 1);
        assertEq(page[0].seriesId, bytes32(uint256(3)));
    }

    function testPagingCountAndIndexFailures() public {
        vm.mockCallRevert(address(book), abi.encodeWithSelector(IMontionsBook.seriesCount.selector), "failed");
        assertEq(quoter.snapshots(0, 50).length, 0);
        vm.clearMockedCalls();
        vm.mockCallRevert(address(book), abi.encodeWithSelector(IMontionsBook.seriesIdAt.selector), "failed");
        IQuoter.Snapshot[] memory page = quoter.snapshots(0, 50);
        assertEq(page.length, 1);
        assertEq(page[0].seriesId, bytes32(0));
    }

    function testPagingEmptyBook() public {
        Quoter empty = new Quoter(address(new MockBook()), address(resolver));
        assertEq(empty.snapshots(0, 50).length, 0);
    }
}
