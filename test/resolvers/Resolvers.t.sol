// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {TwapThresholdResolver} from "../../src/resolvers/TwapThresholdResolver.sol";
import {TimelockOpResolver} from "../../src/resolvers/TimelockOpResolver.sol";
import {LibString} from "solady/utils/LibString.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockTimelock} from "./mocks/MockTimelock.sol";

contract ResolversTest is Test {
    uint64 internal constant START = 1_700_000_000;
    bytes32 internal constant ASSET = keccak256("MON");
    bytes32 internal constant OTHER_ASSET = keccak256("NVDA");
    uint256 internal constant STRIKE = 1.5e18;

    TwapThresholdResolver internal twap;
    TimelockOpResolver internal timelockResolver;
    MockOracle internal oracle;
    MockTimelock internal timelock;

    function setUp() public {
        vm.warp(START);
        twap = new TwapThresholdResolver();
        timelockResolver = new TimelockOpResolver();
        oracle = new MockOracle();
        oracle.setAsset(ASSET, true);
        oracle.setPrice(ASSET, STRIKE);
        timelock = new MockTimelock();
    }

    function testTwapEncodeDecodeAndValidate() public {
        bytes memory data = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        (address decodedOracle, bytes32 assetId, uint256 strike, bool above, uint32 window) = twap.decode(data);
        assertEq(decodedOracle, address(oracle));
        assertEq(assetId, ASSET);
        assertEq(strike, STRIKE);
        assertTrue(above);
        assertEq(window, 60);

        twap.validate(data, uint64(block.timestamp + 1 days));
        twap.validate(twap.encode(address(oracle), ASSET, STRIKE, true, 30), uint64(block.timestamp + 1 days));
        twap.validate(twap.encode(address(oracle), ASSET, STRIKE, true, 3600), uint64(block.timestamp + 1 days));

        bytes memory otherData = twap.encode(address(oracle), OTHER_ASSET, STRIKE, true, 60);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.UnknownAsset.selector, OTHER_ASSET));
        twap.validate(otherData, uint64(block.timestamp + 1 days));
    }

    function testTwapValidateRejectsMalformedAndInvalidFields() public {
        vm.expectRevert(TwapThresholdResolver.InvalidData.selector);
        twap.validate(new bytes(0), uint64(block.timestamp + 1 days));

        bytes memory malformed = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        // A bool ABI word may only contain 0 or 1. This must fail in decode.
        assembly {
            mstore(add(malformed, 0x80), 2)
        }
        vm.expectRevert();
        twap.decode(malformed);

        bytes memory malformedAddress = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        // Address ABI words must have zeroes in their high 12 bytes.
        assembly {
            mstore(add(malformedAddress, 0x20), shl(160, 1))
        }
        vm.expectRevert();
        twap.decode(malformedAddress);

        bytes memory malformedWindow = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        // A uint32 ABI word must have zeroes in its high 28 bytes.
        assembly {
            mstore(add(malformedWindow, 0xa0), shl(32, 1))
        }
        vm.expectRevert();
        twap.decode(malformedWindow);

        bytes memory zeroOracleData = twap.encode(address(0), ASSET, STRIKE, true, 60);
        vm.expectRevert(TwapThresholdResolver.ZeroOracle.selector);
        twap.validate(zeroOracleData, uint64(block.timestamp + 1 days));

        bytes memory zeroStrikeData = twap.encode(address(oracle), ASSET, 0, true, 60);
        vm.expectRevert(TwapThresholdResolver.InvalidStrike.selector);
        twap.validate(zeroStrikeData, uint64(block.timestamp + 1 days));

        bytes memory shortWindowData = twap.encode(address(oracle), ASSET, STRIKE, true, 29);
        vm.expectRevert(abi.encodeWithSelector(TwapThresholdResolver.InvalidWindow.selector, 29));
        twap.validate(shortWindowData, uint64(block.timestamp + 1 days));

        bytes memory longWindowData = twap.encode(address(oracle), ASSET, STRIKE, true, 3601);
        vm.expectRevert(abi.encodeWithSelector(TwapThresholdResolver.InvalidWindow.selector, 3601));
        twap.validate(longWindowData, uint64(block.timestamp + 1 days));

        bytes memory expiredData = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        vm.expectRevert(abi.encodeWithSelector(TwapThresholdResolver.InvalidExpiry.selector, START));
        twap.validate(expiredData, START);

        vm.warp(1);
        bytes memory shortExpiryData = twap.encode(address(oracle), ASSET, STRIKE, true, 30);
        vm.expectRevert(abi.encodeWithSelector(TwapThresholdResolver.InvalidExpiry.selector, uint64(10)));
        twap.validate(shortExpiryData, uint64(10));
    }

    function testTwapResolveReadinessBoundaryAndBothDirections() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory aboveData = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        bytes memory belowData = twap.encode(address(oracle), ASSET, STRIKE, false, 60);

        (bool ready, bool yes) = twap.resolve(aboveData, expiry);
        assertFalse(ready);
        assertFalse(yes);

        vm.warp(expiry);
        (ready, yes) = twap.resolve(aboveData, expiry);
        assertFalse(ready);
        assertFalse(yes);

        vm.warp(uint256(expiry) + 1);
        // Equality is YES for above and NO for below.
        vm.expectCall(address(oracle), abi.encodeCall(IPriceOracle.twapAt, (ASSET, expiry, uint32(60))));
        (ready, yes) = twap.resolve(aboveData, expiry);
        assertTrue(ready);
        assertTrue(yes);
        (ready, yes) = twap.resolve(belowData, expiry);
        assertTrue(ready);
        assertFalse(yes);

        oracle.setPrice(ASSET, STRIKE - 1);
        (ready, yes) = twap.resolve(aboveData, expiry);
        assertTrue(ready);
        assertFalse(yes);
        (ready, yes) = twap.resolve(belowData, expiry);
        assertTrue(ready);
        assertTrue(yes);

        oracle.setPrice(ASSET, STRIKE + 1);
        (ready, yes) = twap.resolve(aboveData, expiry);
        assertTrue(ready);
        assertTrue(yes);
        (ready, yes) = twap.resolve(belowData, expiry);
        assertTrue(ready);
        assertFalse(yes);

        vm.expectRevert(TwapThresholdResolver.InvalidData.selector);
        twap.resolve(new bytes(0), expiry);
    }

    function testTwapResolveOracleRevertIsNotReady() public {
        uint64 expiry = uint64(block.timestamp + 60);
        bytes memory data = twap.encode(address(oracle), ASSET, STRIKE, true, 30);
        vm.warp(uint256(expiry) + 1);
        oracle.setTwapFails(true);

        (bool ready, bool yes) = twap.resolve(data, expiry);
        assertFalse(ready);
        assertFalse(yes);
    }

    function testResolversResolveUnderGasLimit() public {
        uint64 expiry = uint64(block.timestamp);
        bytes memory twapData = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        bytes32 operationId = keccak256("gas");
        bytes memory timelockData = timelockResolver.encode(address(timelock), operationId);
        vm.warp(uint256(expiry) + 1);

        uint256 beforeGas = gasleft();
        twap.resolve(twapData, expiry);
        uint256 twapGas = beforeGas - gasleft();
        assertLt(twapGas, 300_000);

        beforeGas = gasleft();
        timelockResolver.resolve(timelockData, expiry);
        uint256 timelockGas = beforeGas - gasleft();
        assertLt(timelockGas, 300_000);
    }

    function testTwapSymbolRegistryAndFallbackDescription() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory data = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        string memory fallbackDescription = twap.describe(data, expiry);
        assertEq(
            fallbackDescription,
            string.concat(LibString.toHexString(uint256(ASSET), 32), " >= $1.50 at 2023-11-15 22:13 UTC (60s TWAP)")
        );

        twap.setSymbol(ASSET, "MON");
        string memory symbolDescription = twap.describe(data, expiry);
        assertEq(symbolDescription, "MON >= $1.50 at 2023-11-15 22:13 UTC (60s TWAP)");
        bytes memory belowData = twap.encode(address(oracle), ASSET, STRIKE, false, 60);
        assertEq(twap.describe(belowData, expiry), "MON < $1.50 at 2023-11-15 22:13 UTC (60s TWAP)");
        assertEq(twap.symbolOf(ASSET), "MON");
        twap.setSymbol(ASSET, "");
        assertEq(twap.describe(data, expiry), fallbackDescription);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        twap.setSymbol(ASSET, "HACK");
    }

    function testTimelockEncodeDecodeValidateAndDescribe() public {
        bytes32 operationId = keccak256("upgrade");
        bytes memory data = timelockResolver.encode(address(timelock), operationId);
        (address decodedTimelock, bytes32 decodedOperation) = timelockResolver.decode(data);
        assertEq(decodedTimelock, address(timelock));
        assertEq(decodedOperation, operationId);

        timelockResolver.validate(data, uint64(block.timestamp + 1 days));
        assertEq(
            timelockResolver.describe(data, uint64(block.timestamp + 1 days)),
            string.concat(
                "Timelock op ",
                LibString.slice(LibString.toHexString(uint256(operationId), 32), 0, 10),
                "... done on ",
                LibString.toHexStringChecksummed(address(timelock)),
                " (checked after 2023-11-15 22:13 UTC)"
            )
        );

        vm.expectRevert(TimelockOpResolver.BadData.selector);
        timelockResolver.validate(new bytes(0), uint64(block.timestamp + 1 days));

        bytes memory zeroTimelockData = timelockResolver.encode(address(0), operationId);
        (address zeroDecoded,) = timelockResolver.decode(zeroTimelockData);
        assertEq(zeroDecoded, address(0));
        vm.expectRevert(TimelockOpResolver.ZeroTimelock.selector);
        timelockResolver.validate(zeroTimelockData, uint64(block.timestamp + 1 days));

        bytes memory zeroOperationData = timelockResolver.encode(address(timelock), bytes32(0));
        (, bytes32 zeroOperationDecoded) = timelockResolver.decode(zeroOperationData);
        assertEq(zeroOperationDecoded, bytes32(0));
        vm.expectRevert(TimelockOpResolver.ZeroOperation.selector);
        timelockResolver.validate(zeroOperationData, uint64(block.timestamp + 1 days));
    }

    function testTimelockResolveReadinessAndStatusAtResolveTime() public {
        bytes32 operationId = keccak256("migration");
        bytes memory data = timelockResolver.encode(address(timelock), operationId);
        uint64 expiry = uint64(block.timestamp + 1 hours);

        (bool ready, bool yes) = timelockResolver.resolve(data, expiry);
        assertFalse(ready);
        assertFalse(yes);

        vm.warp(expiry);
        (ready, yes) = timelockResolver.resolve(data, expiry);
        assertFalse(ready);
        assertFalse(yes);

        vm.warp(uint256(expiry) + 1);
        (ready, yes) = timelockResolver.resolve(data, expiry);
        assertTrue(ready);
        assertFalse(yes);

        // The status is deliberately read at resolve time, so a late execution
        // is observed as YES when the keeper resolves the series.
        timelock.setDone(operationId, true);
        (ready, yes) = timelockResolver.resolve(data, expiry);
        assertTrue(ready);
        assertTrue(yes);
    }

    function testTimelockMalformedAddressAndPostExpiryData() public {
        bytes memory malformed = abi.encode(address(timelock), keccak256("operation"));
        assembly { mstore(add(malformed, 0x20), shl(160, 1)) }
        vm.expectRevert();
        timelockResolver.decode(malformed);
        uint64 expiry = START;
        vm.warp(uint256(expiry) + 1);
        vm.expectRevert(TimelockOpResolver.BadData.selector);
        timelockResolver.resolve(new bytes(0), expiry);
    }

    function testTwapValidationOracleFailureAndUnknownAssetResolution() public {
        bytes memory data = twap.encode(address(oracle), ASSET, STRIKE, true, 60);
        oracle.setAssetExistsFails(true);
        vm.expectRevert(MockOracle.TwapFailed.selector);
        twap.validate(data, START + 1 days);
        oracle.setAssetExistsFails(false);
        oracle.setAsset(ASSET, false);
        vm.warp(uint256(START) + 1);
        (bool ready, bool yes) = twap.resolve(data, START);
        assertFalse(ready);
        assertFalse(yes);
    }

    function testTimelockStatusRevertBubblesToBookBoundary() public {
        bytes32 operationId = keccak256("revert");
        bytes memory data = timelockResolver.encode(address(timelock), operationId);
        uint64 expiry = uint64(block.timestamp);
        vm.warp(uint256(expiry) + 1);
        timelock.setStatusFails(true);

        vm.expectRevert(MockTimelock.StatusFailed.selector);
        timelockResolver.resolve(data, expiry);
    }
}
