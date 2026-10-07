// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Test-only timelock implementing the one method consumed by the resolver.
contract MockTimelock {
    error StatusFailed();

    mapping(bytes32 => bool) private _done;
    bool public statusFails;

    function setDone(bytes32 operationId, bool done) external {
        _done[operationId] = done;
    }

    function setStatusFails(bool fails) external {
        statusFails = fails;
    }

    function isOperationDone(bytes32 operationId) external view returns (bool) {
        if (statusFails) revert StatusFailed();
        return _done[operationId];
    }
}
