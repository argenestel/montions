// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IResolver} from "../interfaces/IResolver.sol";
import {Ownable} from "solady/auth/Ownable.sol";
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
///      (the Book is expected to resolve promptly; keepers do). A reverting timelock is "not ready".
///      The owner manages which timelocks may be used when creating markets.
contract TimelockOpResolver is IResolver, Ownable {
    error ZeroTimelock();
    error ZeroOperation();
    error BadData();
    error TimelockNotAllowed();

    /// @notice Timelocks accepted when creating a market.
    mapping(address => bool) public timelockAllowed;

    event TimelockAllowedSet(address indexed timelock, bool allowed);

    constructor(address owner_) {
        _initializeOwner(owner_);
    }

    /// @notice Allow or disallow a timelock for new markets (owner only).
    function setTimelockAllowed(address timelock, bool allowed) external onlyOwner {
        timelockAllowed[timelock] = allowed;
        emit TimelockAllowedSet(timelock, allowed);
    }

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
    function validate(bytes calldata data, uint64) external view {
        if (data.length > 512) revert BadData();
        (address timelock, bytes32 operationId) = decode(data);
        if (timelock == address(0)) revert ZeroTimelock();
        if (operationId == bytes32(0)) revert ZeroOperation();
        if (!timelockAllowed[timelock]) revert TimelockNotAllowed();
    }

    /// @inheritdoc IResolver
    function resolve(bytes calldata data, uint64 expiry) external view returns (bool ready, bool yes) {
        if (block.timestamp <= expiry) return (false, false);
        (address timelock, bytes32 operationId) = decode(data);
        try ITimelock(timelock).isOperationDone(operationId) returns (bool done) {
            return (true, done);
        } catch {
            return (false, false);
        }
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
