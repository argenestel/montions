// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @title TestUSDC
/// @notice Six-decimal test collateral with Solady's EIP-2612 permit.
/// @dev The faucet is labelled for tests and grants 10,000 tUSDC per address
///      per hour.
contract TestUSDC is MockERC20 {
    /// @notice Creates the test collateral token.
    /// @param owner_ Address authorized to call `mint`.
    constructor(address owner_) MockERC20("Test USDC", "tUSDC", 6, owner_) {}

    /// @notice Mints the TestUSDC faucet allocation to the caller.
    /// @dev TestUSDC grants 10,000 whole USDC per address per hour.
    function _faucetAmount() internal pure override returns (uint256) {
        return 10_000e6;
    }
}
