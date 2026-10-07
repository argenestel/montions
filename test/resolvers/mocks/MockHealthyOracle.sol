// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockOracle} from "./MockOracle.sol";

/// @dev Optional health guard with healthy, unhealthy, reverting and gas-exhausting modes.
contract MockHealthyOracle is MockOracle {
    uint256 public healthMode;

    function setHealthMode(uint256 mode) external {
        healthMode = mode;
    }

    function isHealthy(bytes32) external view returns (bool) {
        if (healthMode == 2) revert TwapFailed();
        if (healthMode == 3) {
            assembly { for {} 1 {} {} }
        }
        return healthMode == 0;
    }
}
