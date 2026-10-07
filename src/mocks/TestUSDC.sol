// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title TestUSDC
/// @notice MOCK/DEMO 6-decimal collateral token with owner mint and a per-address hourly faucet.
/// @dev EIP-2612 `permit` is provided by Solady ERC20 (emits `Approval`).
contract TestUSDC is ERC20, Ownable {
    /// @dev 10,000 tUSDC (6 decimals) per faucet call.
    uint256 public constant FAUCET_AMOUNT = 10_000e6;

    /// @dev Minimum seconds between faucet calls per address.
    uint256 public constant FAUCET_INTERVAL = 1 hours;

    /// @notice Timestamp of the last successful faucet claim, per address.
    mapping(address => uint256) public lastFaucet;

    error FaucetCooldown();

    /// @param owner_ Account that may call `mint`.
    constructor(address owner_) {
        _initializeOwner(owner_);
    }

    /// @notice Mints `amount` tUSDC to `to`. Owner only.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Claims `FAUCET_AMOUNT` tUSDC. Limited to once per `FAUCET_INTERVAL` per caller.
    function faucet() external {
        uint256 last = lastFaucet[msg.sender];
        if (last != 0 && block.timestamp < last + FAUCET_INTERVAL) revert FaucetCooldown();
        lastFaucet[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    function name() public pure override returns (string memory) {
        return "Test USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "tUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function _constantNameHash() internal pure override returns (bytes32) {
        return keccak256("Test USDC");
    }
}
