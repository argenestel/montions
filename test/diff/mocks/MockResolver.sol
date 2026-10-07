// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IResolver} from "../../../src/interfaces/IResolver.sol";

/// @notice Vector resolver: data is abi.encode(uint256 outcome), 0=NO, 1=YES, 2=not-ready/void.
contract MockResolver is IResolver {
    function validate(bytes calldata data, uint64) external pure {
        require(data.length == 32, "BAD_DATA");
    }

    function resolve(bytes calldata data, uint64 expiry) external view returns (bool ready, bool yes) {
        uint256 outcome = abi.decode(data, (uint256));
        return (block.timestamp > expiry && outcome != 2, outcome == 1);
    }

    function describe(bytes calldata, uint64) external pure returns (string memory) {
        return "DIFF TEST MARKET";
    }
}
