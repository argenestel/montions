// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibString} from "solady/utils/LibString.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

/// @dev Small string helpers shared by the resolvers' `describe`.
library ResolverFormat {
    /// @notice "YYYY-MM-DD HH:MM UTC"
    function utc(uint256 ts) internal pure returns (string memory) {
        if (!DateTimeLib.isSupportedTimestamp(ts)) return string.concat(LibString.toString(ts), " (unix)");
        (uint256 y, uint256 mo, uint256 d, uint256 h, uint256 mi,) = DateTimeLib.timestampToDateTime(ts);
        return string.concat(LibString.toString(y), "-", _p2(mo), "-", _p2(d), " ", _p2(h), ":", _p2(mi), " UTC");
    }

    /// @notice "$1.50", "$180.00", "$0.123456": USD from a WAD price; at least 2 decimals, up to 6 (18 if the price is < 1e-6).
    function usd(uint256 wad) internal pure returns (string memory) {
        uint256 whole = wad / 1e18;
        uint256 frac = wad % 1e18;
        uint256 digits = 6;
        if (whole == 0 && frac < 1e12) digits = 18;
        frac = frac / (10 ** (18 - digits));
        // strip trailing zeros down to 2 digits
        while (digits > 2 && frac % 10 == 0) {
            frac /= 10;
            digits--;
        }
        string memory f = LibString.toString(frac);
        return string.concat("$", LibString.toString(whole), ".", LibString.repeat("0", digits - bytes(f).length), f);
    }

    function _p2(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", LibString.toString(v)) : LibString.toString(v);
    }
}
