// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MakerVault} from "../../../src/MakerVault.sol";

/// @title ReentrantBook
/// @notice Minimal Book stub that reenters MakerVault.deposit from `deposit`.
contract ReentrantBook {
    address public collateral;
    MakerVault public vault;
    mapping(address => uint256) public cash;
    mapping(address => uint256) public lockedCash;

    constructor(address collateral_) {
        collateral = collateral_;
    }

    function setVault(MakerVault vault_) external {
        vault = vault_;
    }

    function deposit(uint256) external {
        vault.deposit(1, msg.sender);
    }

    function withdraw(uint256) external {}
}
