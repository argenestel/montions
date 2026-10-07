// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PythTestBase} from "./PythTestBase.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {PythOracle} from "../../src/oracle/pyth/PythOracle.sol";

contract PythOracleTest is PythTestBase {
    function testNormalisesAcrossSupportedExponents() public {
        (uint256 basePrice,) = oracle.latestPrice(ASSET);
        assertEq(basePrice, 1e18);

        bytes32 assetMinus8 = keccak256("expo-minus-8");
        bytes32 feedMinus8 = bytes32(uint256(0x101));
        pyth.setPrice(feedMinus8, 2_596_750, 1, -8, block.timestamp);
        oracle.setFeed(assetMinus8, feedMinus8, 0.8e18, 60);
        (uint256 price, uint64 updatedAt) = oracle.latestPrice(assetMinus8);
        assertEq(price, 25_967_500_000_000_000);
        assertEq(updatedAt, block.timestamp);

        bytes32 assetMinus18 = keccak256("expo-minus-18");
        bytes32 feedMinus18 = bytes32(uint256(0x102));
        pyth.setPrice(feedMinus18, 7, 0, -18, block.timestamp);
        oracle.setFeed(assetMinus18, feedMinus18, 0.2e18, 10);
        (uint256 tinyPrice,) = oracle.latestPrice(assetMinus18);
        assertEq(tinyPrice, 7);

        bytes32 assetZero = keccak256("expo-zero");
        bytes32 feedZero = bytes32(uint256(0x103));
        pyth.setPrice(feedZero, 4, 0, 0, block.timestamp);
        oracle.setFeed(assetZero, feedZero, 5e18, 3600);
        (uint256 unitPrice,) = oracle.latestPrice(assetZero);
        assertEq(unitPrice, 4e18);
    }

    function testLatestPriceRejectsNonPositivePriceAndUnsupportedExponent() public {
        bytes32 negativeAsset = keccak256("negative");
        bytes32 negativeFeed = bytes32(uint256(0x201));
        pyth.setPrice(negativeFeed, -1, 0, -8, block.timestamp);
        oracle.setFeed(negativeAsset, negativeFeed, 0.8e18, 60);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidPrice.selector, int64(-1)));
        oracle.latestPrice(negativeAsset);

        bytes32 exponentAsset = keccak256("bad-exponent");
        bytes32 exponentFeed = bytes32(uint256(0x202));
        pyth.setPrice(exponentFeed, 1, 0, 1, block.timestamp);
        oracle.setFeed(exponentAsset, exponentFeed, 0.8e18, 60);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidExponent.selector, int32(1)));
        oracle.latestPrice(exponentAsset);
    }

    function testStalePriceAndUnknownAssetRevert() public {
        vm.warp(START + 61);
        vm.expectRevert();
        oracle.latestPrice(ASSET);
        assertFalse(oracle.assetExists(keccak256("missing")));
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.UnknownAsset.selector, keccak256("missing")));
        oracle.latestPrice(keccak256("missing"));
    }

    function testSetFeedBoundsAndFeedExistence() public {
        bytes32 asset = keccak256("bounds");
        bytes32 feed = bytes32(uint256(0x301));
        pyth.setPrice(feed, 1, 0, -8, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidVolatility.selector, 199_999_999_999_999_999));
        oracle.setFeed(asset, feed, 0.199999999999999999e18, 60);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidVolatility.selector, 5e18 + 1));
        oracle.setFeed(asset, feed, 5e18 + 1, 60);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidMaxAge.selector, uint32(9)));
        oracle.setFeed(asset, feed, 1e18, 9);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.InvalidMaxAge.selector, uint32(3601)));
        oracle.setFeed(asset, feed, 1e18, 3601);
        vm.expectRevert(abi.encodeWithSelector(PythOracle.UnknownFeed.selector, bytes32(uint256(0x302))));
        oracle.setFeed(asset, bytes32(uint256(0x302)), 1e18, 60);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        oracle.setFeed(asset, feed, 1e18, 60);

        oracle.setFeed(asset, feed, 0.2e18, 10);
        assertTrue(oracle.assetExists(asset));
        assertEq(oracle.realizedVol(asset, 1, 2), 0.2e18);
    }

    function testHealthyRequiresFreshPriceAndAtMostTwoPercentConfidence() public {
        pyth.setPrice(FEED, 100_000_000, 2_000_000, -8, block.timestamp);
        assertTrue(oracle.isHealthy(ASSET));
        pyth.setPrice(FEED, 100_000_000, 2_000_001, -8, block.timestamp);
        assertFalse(oracle.isHealthy(ASSET));
        pyth.setPrice(FEED, -1, 0, -8, block.timestamp);
        assertFalse(oracle.isHealthy(ASSET));
        vm.warp(START + 61);
        assertFalse(oracle.isHealthy(ASSET));
        assertFalse(oracle.isHealthy(keccak256("missing")));
    }

    function testTwapAlwaysRevertsAndOwnerCanUseTwoStepHandover() public {
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.HistoryUnavailable.selector, ASSET, uint64(START)));
        oracle.twapAt(ASSET, uint64(START), 60);

        address nextOwner = address(0xAABB);
        vm.prank(nextOwner);
        oracle.requestOwnershipHandover();
        oracle.completeOwnershipHandover(nextOwner);
        assertEq(oracle.owner(), nextOwner);
        vm.prank(nextOwner);
        oracle.setFeed(ASSET, FEED, 1e18, 60);
    }
}
