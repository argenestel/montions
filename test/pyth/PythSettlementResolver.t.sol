// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PythTestBase} from "./PythTestBase.sol";
import {IPyth} from "../../src/oracle/pyth/IPyth.sol";
import {PythSettlementResolver} from "../../src/resolvers/PythSettlementResolver.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {RefundReentrantCaller} from "./mocks/RefundReentrantCaller.sol";

contract PythSettlementResolverTest is PythTestBase {
    function testYesNoAndStrikeEqualityConventions() public {
        uint64 expiryYes = uint64(START + 120);
        bytes[] memory atStrikeYes = _update(FEED, 150_000_000, 1_000_000, -8, expiryYes);
        vm.warp(uint256(expiryYes) + 1);
        resolver.settle{value: 100}(ASSET, expiryYes, atStrikeYes);
        (bool ready, bool yes) = resolver.resolve(_data(1.5e18, true, 300), expiryYes);
        assertTrue(ready);
        assertTrue(yes); // >= includes equality.

        uint64 expiryNo = uint64(START + 500);
        bytes[] memory atStrikeNo = _update(FEED, 150_000_000, 1_000_000, -8, expiryNo);
        vm.warp(uint256(expiryNo) + 1);
        resolver.settle{value: 100}(ASSET, expiryNo, atStrikeNo);
        (ready, yes) = resolver.resolve(_data(1.5e18, false, 300), expiryNo);
        assertTrue(ready);
        assertFalse(yes); // < is strict, so equality is NO.

        uint64 expiryBelow = uint64(START + 900);
        bytes[] memory belowStrike = _update(FEED, 140_000_000, 1_000_000, -8, expiryBelow);
        vm.warp(uint256(expiryBelow) + 1);
        resolver.settle{value: 100}(ASSET, expiryBelow, belowStrike);
        (ready, yes) = resolver.resolve(_data(1.5e18, true, 300), expiryBelow);
        assertTrue(ready);
        assertFalse(yes);
    }

    function testInclusiveSettlementWindowEdgesAndRejectsOutsideUpdates() public {
        uint64 atExpiry = uint64(START + 120);
        bytes[] memory firstEdge = _update(FEED, 120_000_000, 100_000, -8, atExpiry);
        vm.warp(uint256(atExpiry) + 1);
        resolver.settle{value: 100}(ASSET, atExpiry, firstEdge);
        assertTrue(resolver.isSettled(ASSET, atExpiry));

        uint64 atUpperEdge = uint64(START + 500);
        bytes[] memory upperEdge = _update(FEED, 130_000_000, 100_000, -8, uint256(atUpperEdge) + 300);
        vm.warp(uint256(atUpperEdge) + 301);
        resolver.settle{value: 100}(ASSET, atUpperEdge, upperEdge);
        assertTrue(resolver.isSettled(ASSET, atUpperEdge));

        uint64 tooEarlyExpiry = uint64(START + 900);
        bytes[] memory tooEarly = _update(FEED, 130_000_000, 100_000, -8, tooEarlyExpiry - 1);
        vm.warp(uint256(tooEarlyExpiry) + 1);
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        resolver.settle{value: 100}(ASSET, tooEarlyExpiry, tooEarly);
        assertFalse(resolver.isSettled(ASSET, tooEarlyExpiry));

        uint64 tooLateExpiry = uint64(START + 1300);
        bytes[] memory tooLate = _update(FEED, 130_000_000, 100_000, -8, uint256(tooLateExpiry) + 301);
        vm.warp(uint256(tooLateExpiry) + 302);
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        resolver.settle{value: 100}(ASSET, tooLateExpiry, tooLate);
        assertFalse(resolver.isSettled(ASSET, tooLateExpiry));
    }

    function testUniqueFirstUpdatePreventsChoosingALaterPrice() public {
        uint64 expiry = uint64(START + 1200);
        bytes[] memory first = _update(FEED, 100_000_000, 100_000, -8, uint256(expiry) + 50);
        bytes[] memory later = _update(FEED, 200_000_000, 100_000, -8, uint256(expiry) + 200);
        vm.warp(uint256(expiry) + 301);

        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        resolver.settle{value: 100}(ASSET, expiry, later);

        IPyth.PriceFeed memory forgedFirst = pyth.historyAt(FEED, 1);
        forgedFirst.price.price = 90_000_000;
        bytes[] memory forged = new bytes[](1);
        forged[0] = pyth.encodeUpdate(forgedFirst);
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        resolver.settle{value: 100}(ASSET, expiry, forged);

        bytes[] memory both = new bytes[](2);
        both[0] = later[0];
        both[1] = first[0];
        resolver.settle{value: 200}(ASSET, expiry, both);
        (int256 priceWad, uint64 publishTime,, bool valid) = resolver.settlements(ASSET, expiry);
        assertTrue(valid);
        assertEq(priceWad, int256(1e18));
        assertEq(publishTime, uint64(uint256(expiry) + 50));
    }

    function testFeePaymentRefundAndRefundReentrancyAreSafe() public {
        uint64 expiry = uint64(START + 120);
        bytes[] memory data = _update(FEED, 125_000_000, 100_000, -8, uint256(expiry) + 300);
        vm.warp(uint256(expiry) + 301);
        RefundReentrantCaller caller = new RefundReentrantCaller(resolver);
        uint256 amountSent = 100 + 777;
        vm.deal(address(this), amountSent);
        caller.settle{value: amountSent}(ASSET, expiry, data);

        assertEq(address(pyth).balance, 100);
        assertEq(address(caller).balance, 777);
        assertTrue(caller.attempted());
        assertFalse(caller.reentrySucceeded());
        (int256 priceWad, uint64 publishTime, uint64 conf, bool valid) = resolver.settlements(ASSET, expiry);
        assertEq(priceWad, int256(1.25e18));
        assertEq(publishTime, uint64(uint256(expiry) + 300));
        assertEq(conf, 100_000);
        assertTrue(valid);

        vm.expectRevert(abi.encodeWithSelector(PythSettlementResolver.AlreadySettled.selector, ASSET, expiry));
        resolver.settle(ASSET, expiry, data);
    }

    function testPermissionlessCallerCanPayExactFee() public {
        uint64 expiry = uint64(START + 120);
        bytes[] memory data = _update(FEED, 110_000_000, 100_000, -8, expiry);
        vm.warp(uint256(expiry) + 1);
        address keeper = address(0xCAFE);
        vm.deal(keeper, 100);
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        resolver.settle{value: 100}(ASSET, expiry, data);
        uint256 settleGas = gasBefore - gasleft();
        emit log_named_uint("PythSettlementResolver.settle() gas", settleGas);
        assertTrue(resolver.isSettled(ASSET, expiry));
        assertEq(address(pyth).balance, 100);
    }

    function testInvalidConfidenceIsPersistedAsNotReady() public {
        uint64 expiry = uint64(START + 120);
        bytes[] memory data = _update(FEED, 100_000_000, 2_000_001, -8, expiry);
        vm.warp(uint256(expiry) + 1);
        resolver.settle{value: 100}(ASSET, expiry, data);
        (int256 priceWad,,, bool valid) = resolver.settlements(ASSET, expiry);
        assertEq(priceWad, int256(1e18));
        assertFalse(valid);
        (bool ready, bool yes) = resolver.resolve(_data(1e18, true, 300), expiry);
        assertFalse(ready);
        assertFalse(yes);

        uint64 negativeExpiry = uint64(START + 500);
        bytes[] memory negativePrice = _update(FEED, -100_000_000, 0, -8, negativeExpiry);
        vm.warp(uint256(negativeExpiry) + 1);
        resolver.settle{value: 100}(ASSET, negativeExpiry, negativePrice);
        (priceWad,,, valid) = resolver.settlements(ASSET, negativeExpiry);
        assertEq(priceWad, -int256(1e18));
        assertFalse(valid);
        (ready, yes) = resolver.resolve(_data(1e18, true, 300), negativeExpiry);
        assertFalse(ready);
        assertFalse(yes);
    }

    function testValidateRejectsBadDefinitionsAndOversizedData() public {
        uint64 expiry = uint64(START + 120);
        resolver.validate(_data(1e18, true, 300), expiry);

        vm.expectRevert(PythSettlementResolver.InvalidData.selector);
        resolver.validate(bytes("bad"), expiry);
        vm.expectRevert(PythSettlementResolver.InvalidData.selector);
        resolver.validate(new bytes(513), expiry);

        vm.expectRevert(PythSettlementResolver.UntrustedOracle.selector);
        resolver.validate(abi.encode(address(0xBAD), ASSET, uint256(1e18), true, uint32(300)), expiry);
        vm.expectRevert(PythSettlementResolver.InvalidStrike.selector);
        resolver.validate(_data(0, true, 300), expiry);
        vm.expectRevert(abi.encodeWithSelector(PythSettlementResolver.InvalidMaxDelay.selector, uint32(30)));
        resolver.validate(_data(1e18, true, 30), expiry);
        vm.expectRevert(abi.encodeWithSelector(PythSettlementResolver.InvalidMaxDelay.selector, uint32(301)));
        resolver.validate(_data(1e18, true, 301), expiry);
        vm.expectRevert(abi.encodeWithSelector(PythSettlementResolver.InvalidExpiry.selector, uint64(START)));
        resolver.validate(_data(1e18, true, 300), uint64(START));
        vm.expectRevert();
        resolver.validate(abi.encode(address(oracle), keccak256("missing"), uint256(1e18), true, uint32(300)), expiry);
    }
}
