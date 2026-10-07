// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

/// @title PricingLib
/// @notice WAD (1e18) fixed-point helpers for the model fair value of a digital (cash-or-nothing) option with zero rate.
/// @dev MODEL ONLY: lognormal, zero drift, zero rate, constant vol. It is a quoting aid for the Quoter / MakerVault and
///      is never used to settle anything.
///
///      normCdfWad uses Hart's (1968) double-precision rational approximation of the standard normal CDF, in the
///      form published by G. West ("Better approximations to cumulative normal functions", 2005): for |x| < 7.0711 a
///      degree-6 / degree-7 rational function times exp(-x^2/2), and for larger |x| a continued-fraction tail. Its
///      measured maximum absolute error against Python math.erf over [-10,10], including the branch boundary,
///      is 159 WAD units (1.59e-16); see test/pricing/golden.json. The spec tolerance is 1e-4. The lower tail
///      q = N(-|x|) is computed once and mirrored: N(x) = 1 - q for x > 0, so N(-x) + N(x) == 1e18 exactly.
///      Adjacent-input monotonicity and both branch boundaries are covered by property / regression tests.
library PricingLib {
    uint256 internal constant WAD = 1e18;
    /// @dev Year = 365 days.
    uint256 internal constant YEAR = 365 days;

    /// @dev |x| at/above which N(-|x|) < 1.2e-19, i.e. rounds to 0 wei; also bounds all fixed-point intermediates.
    int256 private constant CDF_CLAMP = 9e18;
    /// @dev West/Hart branch point (5 * sqrt(2)).
    uint256 private constant HART_SPLIT = 7071067811865470000;

    /// @dev Inputs are clamped to keep every intermediate far inside int256/uint256 range.
    uint256 private constant MAX_PRICE = 1e36; // 1e18 whole units, far beyond any sane asset
    uint256 private constant MAX_VOL = 1_000e18; // 100,000 %
    uint256 private constant MAX_SECONDS = 1000 * 365 days;

    /*//////////////////////////////////////////////////////////////
                                 N(x)
    //////////////////////////////////////////////////////////////*/

    /// @notice Standard normal CDF N(x), WAD in / WAD out, result in [0, 1e18].
    /// @param xWad x scaled by 1e18 (any int256; |x| >= 9 saturates to 0 / 1e18).
    function normCdfWad(int256 xWad) internal pure returns (uint256 pWad) {
        if (xWad <= -CDF_CLAMP) return 0;
        if (xWad >= CDF_CLAMP) return WAD;
        bool neg = xWad < 0;
        // The early clamps make negation safe even for int256.min, and the magnitude nonnegative.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ax = uint256(neg ? -xWad : xWad);
        uint256 q = _lowerTail(ax); // N(-|x|)
        pWad = neg ? q : WAD - q;
    }

    /// @dev N(-ax) for ax >= 0 (WAD), Hart/West algorithm.
    function _lowerTail(uint256 ax) private pure returns (uint256 q) {
        // Caller bounds ax below 9e18, far below int256.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 x = int256(ax);
        // e = exp(-x^2 / 2)
        int256 e = FPM.expWad(-int256(FPM.mulWad(ax, ax) / 2));
        if (ax < HART_SPLIT) {
            // numerator polynomial (Horner)
            int256 n = _mul(35262496599891100, x) + 700383064443688000;
            n = _mul(n, x) + 6373962203531650000;
            n = _mul(n, x) + 33912866078383000000;
            n = _mul(n, x) + 112079291497871000000;
            n = _mul(n, x) + 221213596169931000000;
            n = _mul(n, x) + 220206867912376000000;
            // denominator polynomial
            int256 d = _mul(88388347648318400, x) + 1755667163182640000;
            d = _mul(d, x) + 16064177579207000000;
            d = _mul(d, x) + 86780732202946100000;
            d = _mul(d, x) + 296564248779674000000;
            d = _mul(d, x) + 637333633378831000000;
            d = _mul(d, x) + 793826512519948000000;
            d = _mul(d, x) + 440413735824752000000;
            // q = e * n / d
            q = uint256(FPM.sDivWad(_mul(e, n), d));
        } else {
            // continued fraction: b = x + 1/(x + 2/(x + 3/(x + 4/(x + 0.65))))
            int256 b = x + 650000000000000000;
            b = x + FPM.sDivWad(4e18, b);
            b = x + FPM.sDivWad(3e18, b);
            b = x + FPM.sDivWad(2e18, b);
            b = x + FPM.sDivWad(1e18, b);
            // q = e / b / sqrt(2*pi)
            q = uint256(FPM.sDivWad(FPM.sDivWad(e, b), 2506628274631000000));
        }
        if (q > WAD / 2) q = WAD / 2; // guard against rounding at x ~ 0
    }

    function _mul(int256 a, int256 b) private pure returns (int256) {
        return FPM.sMulWad(a, b);
    }

    /*//////////////////////////////////////////////////////////////
                         digital option fair value
    //////////////////////////////////////////////////////////////*/

    /// @notice Model probability that the underlying settles above (or below) the strike: N(d2), r = 0.
    /// @dev d2 = (ln(S/K) - sigma^2 T / 2) / (sigma sqrt(T)); `above == false` returns P(S_T < K) = N(-d2) = 1 - N(d2).
    ///      Settlement convention matches TwapThresholdResolver: YES(above) iff price >= strike, YES(below) iff price < strike.
    ///      Degenerate cases (never revert):
    ///      - strike == 0: above -> 1, below -> 0. spot == 0 (strike > 0): above -> 0, below -> 1.
    ///      - T == 0 or sigma == 0: resolved by moneyness (spot >= strike -> above is certain).
    ///      - Positive time/vol below WAD resolution: use the ATM limit 0.5, otherwise moneyness.
    ///      - extreme moneyness / tiny vol: d2 saturates and N(.) is clamped to exactly 0 / 1e18.
    ///      Inputs are clamped to sane maxima (price 1e36, vol 100000%, T 1000 years).
    /// @param spotWad current price, 1e18 = $1
    /// @param strikeWad strike price, 1e18 = $1
    /// @param volWad annualised vol, 1e18 = 100%
    /// @param secondsToExpiry seconds until expiry (0 if expired)
    /// @param above true for P(S_T >= K), false for P(S_T < K)
    function digitalProbWad(uint256 spotWad, uint256 strikeWad, uint256 volWad, uint256 secondsToExpiry, bool above)
        internal
        pure
        returns (uint256 pWad)
    {
        if (strikeWad == 0) return above ? WAD : 0;
        if (spotWad == 0) return above ? 0 : WAD;
        if (secondsToExpiry == 0 || volWad == 0) {
            return above == (spotWad >= strikeWad) ? WAD : 0;
        }
        if (spotWad > MAX_PRICE) spotWad = MAX_PRICE;
        if (strikeWad > MAX_PRICE) strikeWad = MAX_PRICE;
        if (volWad > MAX_VOL) volWad = MAX_VOL;
        if (secondsToExpiry > MAX_SECONDS) secondsToExpiry = MAX_SECONDS;

        // total vol: sigma * sqrt(T_years)
        uint256 tv = FPM.mulWad(volWad, FPM.sqrtWad(secondsToExpiry * WAD / YEAR));
        if (tv == 0) {
            // Positive time/vol can underflow the WAD total volatility. Preserve
            // the continuous ATM limit (one half), rather than treating it as expiry.
            if (spotWad == strikeWad) return WAD / 2;
            return above == (spotWad > strikeWad) ? WAD : 0;
        }
        // Compute ln(S/K) as lnS - lnK to avoid divWad truncation for tiny S/K.
        // Prices <= 1e36 and variance <= 1e27 are representable as positive int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 num = FPM.lnWad(int256(spotWad)) - FPM.lnWad(int256(strikeWad)) - int256(FPM.mulWad(tv, tv) / 2);
        // tv <= 1000e18 * sqrt(1000), far below int256.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 d2 = FPM.sDivWad(num, int256(tv));
        pWad = normCdfWad(above ? d2 : -d2);
    }

    /// @notice Round a probability to the nearest tick in 1..99 (ticks are cents of a $1 contract).
    /// @dev Round-half-up; anything below 0.5% maps to 1, above 99.5% to 99, and > 1e18 is treated as 1e18.
    function probToTick(uint256 probWad) internal pure returns (uint8 tick) {
        if (probWad > WAD) probWad = WAD;
        uint256 t = (probWad * 100 + WAD / 2) / WAD;
        if (t < 1) t = 1;
        if (t > 99) t = 99;
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = uint8(t);
    }
}
