// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PythSettlementResolver} from "../../../src/resolvers/PythSettlementResolver.sol";

/// @notice Refund recipient that attempts to reenter settlement during its receive hook.
contract RefundReentrantCaller {
    PythSettlementResolver public immutable resolver;
    bytes32 public assetId;
    uint64 public expiry;
    bool public attempted;
    bool public reentrySucceeded;

    constructor(PythSettlementResolver resolver_) {
        resolver = resolver_;
    }

    function settle(bytes32 assetId_, uint64 expiry_, bytes[] calldata updateData) external payable {
        assetId = assetId_;
        expiry = expiry_;
        resolver.settle{value: msg.value}(assetId_, expiry_, updateData);
    }

    receive() external payable {
        attempted = true;
        (bool success,) =
            address(resolver).call(abi.encodeWithSelector(resolver.settle.selector, assetId, expiry, new bytes[](0)));
        reentrySucceeded = success;
    }
}
