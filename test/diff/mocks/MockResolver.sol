// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IResolver} from "../../../src/interfaces/IResolver.sol";

/// @notice Vector resolver: data is abi.encode(uint256 outcome), 0=NO, 1=YES, 2=not-ready/void.
/// @dev A second `true` word forces readiness at exact expiry to test the Book's strict A6 boundary.
contract MockResolver is IResolver {
    function validate(bytes calldata, uint64) external pure {}

    function resolve(bytes calldata data, uint64 expiry) external view returns (bool ready, bool yes) {
        uint256 outcome;
        bool readyAtExpiry;
        if (data.length >= 64) {
            (outcome, readyAtExpiry) = abi.decode(data, (uint256, bool));
        } else {
            outcome = abi.decode(data, (uint256));
        }
        ready = (block.timestamp > expiry || (readyAtExpiry && block.timestamp == expiry)) && outcome != 2;
        yes = outcome == 1;
    }

    function describe(bytes calldata, uint64) external pure returns (string memory) {
        return "DIFF TEST MARKET";
    }
}
