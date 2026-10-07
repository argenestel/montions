// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IResolver} from "../interfaces/IResolver.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ResolverFormat} from "./ResolverFormat.sol";

/// @notice Minimal view of a governance timelock exposing operation execution status
///         (OpenZeppelin TimelockController.isOperationDone matches this signature).
interface ITimelock {
    function isOperationDone(bytes32 id) external view returns (bool);
}

/// @title TimelockOpResolver
/// @notice Checks whether a timelock operation is done when the market is resolved after expiry.
/// @dev data = abi.encode(address timelock, bytes32 operationId). Ready strictly after `expiry`; the outcome is read at
///      resolve time, so an operation executed after expiry but before anyone calls resolve still counts as YES
///      (the Book is expected to resolve promptly; keepers do). A revert of the timelock bubbles up, which the Book
///      treats as "not ready". Stateless and permissionless.
contract TimelockOpResolver is IResolver {
    error ZeroTimelock();
    error ZeroOperation();
    error BadData();

    constructor() {}

    /// @notice abi-encode market data.
    function encode(address timelock, bytes32 operationId) external pure returns (bytes memory) {
        return abi.encode(timelock, operationId);
    }

    /// @notice decode market data.
    function decode(bytes calldata data) public pure returns (address timelock, bytes32 operationId) {
        if (data.length != 64) revert BadData();
        (timelock, operationId) = abi.decode(data, (address, bytes32));
    }

    /// @inheritdoc IResolver
    function validate(bytes calldata data, uint64) external pure {
        (address timelock, bytes32 operationId) = decode(data);
        if (timelock == address(0)) revert ZeroTimelock();
        if (operationId == bytes32(0)) revert ZeroOperation();
    }

    /// @inheritdoc IResolver
    function resolve(bytes calldata data, uint64 expiry) external view returns (bool ready, bool yes) {
        if (block.timestamp <= expiry) return (false, false);
        (address timelock, bytes32 operationId) = decode(data);
        return (true, ITimelock(timelock).isOperationDone(operationId));
    }

    /// @inheritdoc IResolver
    function describe(bytes calldata data, uint64 expiry) external pure returns (string memory) {
        (address timelock, bytes32 operationId) = decode(data);
        return string.concat(
            "Timelock op ",
            LibString.slice(LibString.toHexString(uint256(operationId), 32), 0, 10),
            "... done on ",
            LibString.toHexStringChecksummed(timelock),
            " (checked after ",
            ResolverFormat.utc(expiry),
            ")"
        );
    }
}
