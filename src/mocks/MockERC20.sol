// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title MockERC20
/// @notice MOCK/DEMO ERC20 with configurable decimals, owner mint, and a per-address hourly faucet.
contract MockERC20 is ERC20, Ownable {
    /// @dev Minimum seconds between faucet calls per address.
    uint256 public constant FAUCET_INTERVAL = 1 hours;

    string internal _name;
    string internal _symbol;
    uint8 internal immutable _decimals;

    /// @notice Timestamp of the last successful faucet claim, per address.
    mapping(address => uint256) public lastFaucet;

    error FaucetCooldown();

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param decimals_ Token decimals (18 for tMON / tNVDA).
    /// @param owner_ Account that may call `mint`.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address owner_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        _initializeOwner(owner_);
    }

    /// @notice Mints `amount` tokens to `to`. Owner only.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Claims `1_000 * 10**decimals` tokens. Limited to once per `FAUCET_INTERVAL` per caller.
    function faucet() external {
        uint256 last = lastFaucet[msg.sender];
        if (last != 0 && block.timestamp < last + FAUCET_INTERVAL) revert FaucetCooldown();
        lastFaucet[msg.sender] = block.timestamp;
        _mint(msg.sender, 1000 * 10 ** uint256(_decimals));
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
