// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Quoter} from "../../src/Quoter.sol";
import {IQuoter} from "../../src/interfaces/IQuoter.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {TwapThresholdResolver} from "../../src/resolvers/TwapThresholdResolver.sol";
import {PythOracle} from "../../src/oracle/pyth/PythOracle.sol";
import {PythSettlementResolver} from "../../src/resolvers/PythSettlementResolver.sol";
import {MockBook} from "./mocks/MockBook.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockPyth} from "../pyth/mocks/MockPyth.sol";

contract QuoterMultiResolverTest is Test {
    uint256 internal constant START = 1_700_000_000;
    bytes32 internal constant ASSET = keccak256("MON");
    bytes32 internal constant FEED = bytes32(uint256(0x31491744));

    MockBook internal book;
    MockPriceOracle internal twapOracle;
    TwapThresholdResolver internal twapResolver;
    MockPyth internal pyth;
    PythOracle internal pythOracle;
    PythSettlementResolver internal pythResolver;
    Quoter internal quoter;
    bytes32 internal constant TWAP_SERIES = bytes32(uint256(1));
    bytes32 internal constant PYTH_SERIES = bytes32(uint256(2));

    function setUp() public {
        vm.warp(START);
        book = new MockBook();
        twapOracle = new MockPriceOracle();
        twapOracle.setAsset(ASSET, true);
        twapOracle.setPrice(ASSET, 1e18);
        twapOracle.setVol(ASSET, 0.7e18);
        twapResolver = new TwapThresholdResolver(address(twapOracle), address(this));

        pyth = new MockPyth();
        pyth.setPrice(FEED, 125_000_000, 100_000, -8, block.timestamp);
        pythOracle = new PythOracle(address(pyth), address(this));
        pythOracle.setFeed(ASSET, FEED, 0.5e18, 60);
        pythResolver = new PythSettlementResolver(address(pyth), address(pythOracle), address(this));

        quoter = new Quoter(address(book), address(twapResolver));
        book.setSeries(
            TWAP_SERIES,
            address(twapResolver),
            abi.encode(address(twapOracle), ASSET, uint256(1e18), true, uint32(60)),
            uint64(START + 3600),
            IMontionsBook.Status.Open,
            false,
            11,
            12,
            uint64(START)
        );
        book.setSeries(
            PYTH_SERIES,
            address(pythResolver),
            abi.encode(address(pythOracle), ASSET, uint256(1e18), true, uint32(300)),
            uint64(START + 3600),
            IMontionsBook.Status.Open,
            false,
            21,
            22,
            uint64(START)
        );
    }

    function testInitialTwapAndOwnerEnabledPythResolverBothModel() public {
        assertEq(quoter.owner(), address(this));
        assertTrue(quoter.isPriceResolver(address(twapResolver)));
        assertFalse(quoter.isPriceResolver(address(pythResolver)));

        (uint8 twapTick, uint256 twapProb, uint256 twapVol, uint256 twapSpot) = quoter.fair(TWAP_SERIES);
        assertGt(twapTick, 0);
        assertGt(twapProb, 0);
        assertEq(twapVol, 0.7e18);
        assertEq(twapSpot, 1e18);
        (uint8 initialPythTick,,,) = quoter.fair(PYTH_SERIES);
        assertEq(initialPythTick, 0);

        quoter.setPriceResolver(address(pythResolver), true);
        (uint8 pythTick, uint256 pythProb, uint256 pythVol, uint256 pythSpot) = quoter.fair(PYTH_SERIES);
        assertGt(pythTick, 0);
        assertGt(pythProb, 0);
        assertEq(pythVol, 0.5e18);
        assertEq(pythSpot, 1.25e18);

        IQuoter.Snapshot memory snap = quoter.snapshot(PYTH_SERIES);
        assertEq(snap.spotWad, 1.25e18);
        assertEq(snap.volWad, 0.5e18);
        assertGt(snap.fairTick, 0);
        assertGt(bytes(snap.title).length, 0);
    }

    function testResolverEnablementIsOwnerOnlyAndCanBeRevoked() public {
        address thirdParty = address(0xBAD);
        vm.prank(thirdParty);
        vm.expectRevert();
        quoter.setPriceResolver(address(pythResolver), true);

        quoter.setPriceResolver(address(pythResolver), true);
        (uint8 enabledTick,,,) = quoter.fair(PYTH_SERIES);
        assertGt(enabledTick, 0);
        quoter.setPriceResolver(address(pythResolver), false);
        (uint8 disabledTick,,,) = quoter.fair(PYTH_SERIES);
        assertEq(disabledTick, 0);

        vm.expectRevert(Quoter.ZeroResolver.selector);
        quoter.setPriceResolver(address(0), true);
    }

    function testUnsupportedOrNonOpenSeriesRemainUnmodelled() public {
        bytes32 unsupported = bytes32(uint256(3));
        book.setSeries(
            unsupported,
            address(0x1234),
            abi.encode(address(pythOracle), ASSET, uint256(1e18), true, uint32(300)),
            uint64(START + 3600),
            IMontionsBook.Status.Open,
            false,
            31,
            32,
            uint64(START)
        );
        quoter.setPriceResolver(address(pythResolver), true);
        (uint8 unsupportedTick,,,) = quoter.fair(unsupported);
        assertEq(unsupportedTick, 0);

        book.setSeries(
            PYTH_SERIES,
            address(pythResolver),
            abi.encode(address(pythOracle), ASSET, uint256(1e18), true, uint32(300)),
            uint64(START + 3600),
            IMontionsBook.Status.Resolved,
            true,
            21,
            22,
            uint64(START)
        );
        (uint8 resolvedTick,,,) = quoter.fair(PYTH_SERIES);
        assertEq(resolvedTick, 0);
    }
}
