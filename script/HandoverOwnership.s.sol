// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IOwnable2 { function owner() external view returns (address); function completeOwnershipHandover(address pendingOwner) external; }

/// @notice Step 2 of the two-step ownership handover. PRECONDITION: the Safe has already executed
///         `requestOwnershipHandover()` on every contract below (within Solady's 48h window).
///         This script, run by the CURRENT owner (the deployer), completes the transfer. It never takes ownership itself.
/// Usage: CONTRACTS=0xBook,0xVault,0xOracle,0xResolver,0xTimelock,0xQuoter NEW_OWNER=0xSafe forge script script/HandoverOwnership.s.sol --rpc-url $RPC --account <keystore> --broadcast
contract HandoverOwnership is Script {
    function run() external {
        address newOwner = vm.envAddress("NEW_OWNER");
        address[] memory list = vm.envAddress("CONTRACTS", ",");
        require(newOwner != address(0), "NEW_OWNER required");
        // Production: the new owner must be a contract (Safe multisig). Rehearsals on a fork may set ALLOW_EOA_OWNER=1.
        require(newOwner.code.length > 0 || vm.envOr("ALLOW_EOA_OWNER", uint256(0)) == 1, "NEW_OWNER must be a contract (Safe) with code");
        vm.startBroadcast();
        for (uint256 i; i < list.length; ++i) {
            require(IOwnable2(list[i]).owner() == msg.sender, "caller is not the current owner");
            IOwnable2(list[i]).completeOwnershipHandover(newOwner);
            require(IOwnable2(list[i]).owner() == newOwner, "handover failed");
            console2.log("handed over", list[i]);
        }
        vm.stopBroadcast();
    }
}
