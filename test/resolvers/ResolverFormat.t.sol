// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ResolverFormat} from "../../src/resolvers/ResolverFormat.sol";

contract ResolverFormatTest is Test {
    function testUsdPrecisionAndPadding() public pure {
        assertEq(ResolverFormat.usd(0), "$0.00");
        assertEq(ResolverFormat.usd(180e18), "$180.00");
        assertEq(ResolverFormat.usd(1.5e18), "$1.50");
        assertEq(ResolverFormat.usd(0.123456e18), "$0.123456");
        assertEq(ResolverFormat.usd(0.000001e18), "$0.000001");
        assertEq(ResolverFormat.usd(1), "$0.000000000000000001");
        assertEq(ResolverFormat.usd(123456789), "$0.000000000123456789");
        assertEq(ResolverFormat.usd(1.123456789e18), "$1.123456");
    }

    function testUtcPaddingAndUnsupportedTimestamp() public pure {
        assertEq(ResolverFormat.utc(0), "1970-01-01 00:00 UTC");
        assertEq(ResolverFormat.utc(1_700_086_400), "2023-11-15 22:13 UTC");
        assertEq(ResolverFormat.utc(type(uint64).max), "18446744073709551615 (unix)");
    }
}
