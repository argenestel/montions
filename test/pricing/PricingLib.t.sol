// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PricingLib} from "../../src/pricing/PricingLib.sol";

contract PricingHarness {
    function cdf(int256 x) external pure returns (uint256) {
        return PricingLib.normCdfWad(x);
    }

    function digital(uint256 s, uint256 k, uint256 v, uint256 t, bool above) external pure returns (uint256) {
        return PricingLib.digitalProbWad(s, k, v, t, above);
    }

    function tick(uint256 p) external pure returns (uint8) {
        return PricingLib.probToTick(p);
    }
}

contract PricingLibTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant YEAR = 365 days;
    PricingHarness harness;

    function setUp() public {
        harness = new PricingHarness();
    }

    function difference(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function golden() internal view returns (string memory) {
        // Read-only access to the checked-in reference table is granted by the test profile.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.readFile(string.concat(vm.projectRoot(), "/test/pricing/golden.json"));
    }

    function testGoldenCdf() public {
        string memory json = golden();
        int256[] memory xs = abi.decode(vm.parseJson(json, ".cdfX"), (int256[]));
        uint256[] memory expected = abi.decode(vm.parseJson(json, ".cdfExpected"), (uint256[]));
        assertEq(xs.length, expected.length);
        uint256 maxError;
        for (uint256 i; i < xs.length; ++i) {
            uint256 err = difference(harness.cdf(xs[i]), expected[i]);
            assertLt(err, 1e14, "CDF absolute error must be < 1e-4");
            if (err > maxError) maxError = err;
        }
        emit log_named_uint("CDF achieved max absolute error (WAD)", maxError);
    }

    function testGoldenDigital() public {
        string memory json = golden();
        uint256[] memory spots = abi.decode(vm.parseJson(json, ".spot"), (uint256[]));
        uint256[] memory strikes = abi.decode(vm.parseJson(json, ".strike"), (uint256[]));
        uint256[] memory vols = abi.decode(vm.parseJson(json, ".vol"), (uint256[]));
        uint256[] memory times = abi.decode(vm.parseJson(json, ".seconds"), (uint256[]));
        uint256[] memory expected = abi.decode(vm.parseJson(json, ".expected"), (uint256[]));
        assertEq(spots.length, strikes.length);
        assertEq(spots.length, vols.length);
        assertEq(spots.length, times.length);
        assertEq(spots.length, expected.length);
        uint256 maxError;
        for (uint256 i; i < spots.length; ++i) {
            uint256 p = harness.digital(spots[i], strikes[i], vols[i], times[i], true);
            uint256 err = difference(p, expected[i]);
            assertLt(err, 1e14, "digital absolute error must be < 1e-4");
            assertEq(harness.digital(spots[i], strikes[i], vols[i], times[i], false), WAD - p);
            if (err > maxError) maxError = err;
        }
        emit log_named_uint("Digital achieved max absolute error (WAD)", maxError);
    }

    function testFuzzGoldenRow(uint256 index) public view {
        string memory json = golden();
        uint256[] memory s = vm.parseJsonUintArray(json, ".spot");
        uint256[] memory k = vm.parseJsonUintArray(json, ".strike");
        uint256[] memory v = vm.parseJsonUintArray(json, ".vol");
        uint256[] memory t = vm.parseJsonUintArray(json, ".seconds");
        uint256[] memory p = vm.parseJsonUintArray(json, ".expected");
        index %= s.length;
        assertLt(difference(harness.digital(s[index], k[index], v[index], t[index], true), p[index]), 1e14);
    }

    function testFuzzCdfMonotoneAndSymmetric(int256 a, int256 b) public view {
        a = bound(a, -10e18, 10e18);
        b = bound(b, a, 10e18);
        assertLe(harness.cdf(a), harness.cdf(b));
        assertEq(harness.cdf(a) + harness.cdf(-a), WAD);
    }

    function testFuzzCdfAdjacentMonotone(int256 x, uint256 delta) public view {
        x = bound(x, -9e18, 9e18);
        delta = bound(delta, 1, 1000);
        // delta is bounded to 1..1000 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLe(harness.cdf(x), harness.cdf(x + int256(delta)));
    }

    function testFuzzCdfNoReverts(int256 x) public view {
        assertLe(harness.cdf(x), WAD);
    }

    function testFuzzDigitalNoRevertsAndComplement(uint256 s, uint256 k, uint256 v, uint256 t) public view {
        uint256 p = harness.digital(s, k, v, t, true);
        assertLe(p, WAD);
        assertEq(p + harness.digital(s, k, v, t, false), WAD);
    }

    function testFuzzDegenerateMoneyness(uint256 s, uint256 k) public view {
        uint256 expected = s >= k ? WAD : 0;
        assertEq(harness.digital(s, k, WAD, 0, true), expected);
        assertEq(harness.digital(s, k, 0, YEAR, true), expected);
        assertEq(harness.digital(s, k, WAD, 0, false), WAD - expected);
    }

    function testFuzzMonotoneStrike(uint256 s, uint256 k1, uint256 k2, uint256 v, uint256 t) public view {
        s = bound(s, 1, 1e36);
        k1 = bound(k1, 1, 1e36);
        k2 = bound(k2, k1, 1e36);
        v = bound(v, 0, 1000e18);
        t = bound(t, 0, 1000 * YEAR);
        assertGe(harness.digital(s, k1, v, t, true), harness.digital(s, k2, v, t, true));
        assertLe(harness.digital(s, k1, v, t, false), harness.digital(s, k2, v, t, false));
    }

    function testCdfBranchAndClampMonotone() public view {
        int256[3] memory boundaries = [int256(0), int256(7071067811865470000), int256(9e18)];
        for (uint256 i; i < boundaries.length; ++i) {
            int256 x = boundaries[i];
            assertLe(harness.cdf(x - 1), harness.cdf(x));
            assertLe(harness.cdf(x), harness.cdf(x + 1));
            assertLe(harness.cdf(-x - 1), harness.cdf(-x));
            assertLe(harness.cdf(-x), harness.cdf(-x + 1));
        }
    }

    function testTinyPositiveVolatilityAtmLimit() public view {
        assertEq(harness.digital(WAD, WAD, 1, 1, true), WAD / 2);
        assertEq(harness.digital(WAD, WAD, 1, 1, false), WAD / 2);
        assertEq(harness.digital(WAD, WAD, 0, 1, true), WAD);
    }

    function testAtmAndYearConvention() public view {
        assertApproxEqAbs(harness.digital(WAD, WAD, 0.8e18, 60, true), WAD / 2, 1e15);
        // d2 = -0.5 for sigma = 1 and T = exactly one 365-day year.
        assertEq(harness.digital(WAD, WAD, WAD, YEAR, true), harness.cdf(-0.5e18));
    }

    function testDegenerateAndExtremeInputs() public view {
        assertEq(harness.cdf(0), WAD / 2);
        assertEq(harness.cdf(type(int256).min), 0);
        assertEq(harness.cdf(type(int256).max), WAD);
        assertEq(harness.digital(WAD, WAD, WAD, 0, true), WAD);
        assertEq(harness.digital(WAD, WAD, 0, YEAR, false), 0);
        assertEq(harness.digital(1, WAD, 0, YEAR, true), 0);
        assertEq(harness.digital(0, WAD, WAD, YEAR, true), 0);
        assertEq(harness.digital(WAD, 0, WAD, YEAR, true), WAD);
        assertEq(harness.digital(1, 1e36, WAD, YEAR, true), 0);
        assertEq(harness.digital(1e36, 1, WAD, YEAR, true), WAD);
        assertEq(harness.digital(WAD, 2 * WAD, 1, 1, true), 0);
        assertEq(harness.digital(2 * WAD, WAD, 1, 1, true), WAD);
    }

    function testTickRoundingAndClamps() public view {
        assertEq(harness.tick(0), 1);
        assertEq(harness.tick(0.014999999999999999e18), 1);
        assertEq(harness.tick(0.015e18), 2);
        assertEq(harness.tick(0.494999999999999999e18), 49);
        assertEq(harness.tick(0.495e18), 50);
        assertEq(harness.tick(WAD), 99);
        assertEq(harness.tick(type(uint256).max), 99);
    }

    function testFuzzTick(uint256 p) public view {
        uint256 clamped = p > WAD ? WAD : p;
        uint256 expected = (clamped + 5e15) / 1e16;
        if (expected < 1) expected = 1;
        if (expected > 99) expected = 99;
        assertEq(harness.tick(p), expected);
    }

    function testGas() public {
        harness.cdf(1e18); // warm external account
        uint256 beforeGas = gasleft();
        harness.cdf(1e18);
        uint256 cdfGas = beforeGas - gasleft();
        beforeGas = gasleft();
        harness.digital(180e18, 175e18, 0.8e18, 7 days, true);
        uint256 digitalGas = beforeGas - gasleft();
        emit log_named_uint("CDF gas (warm external call)", cdfGas);
        emit log_named_uint("Digital gas (warm external call)", digitalGas);
        assertLt(cdfGas, 30_000);
        assertLt(digitalGas, 50_000);
    }
}
