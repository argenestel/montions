// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "../../../lib/solady/src/tokens/ERC20.sol";

/// @title MockERC20
/// @notice Configurable mock ERC20 with Solady's EIP-2612 permit implementation.
/// @dev This token is for tests and demo fixtures. The faucet is rate limited
///      to one claim per address per hour.
contract MockERC20 is ERC20 {
    string private _tokenName;
    string private _tokenSymbol;
    uint8 private immutable _tokenDecimals;

    /// @notice Account allowed to mint test tokens.
    address public immutable owner;

    /// @notice Earliest timestamp at which an address may claim again.
    mapping(address account => uint64 availableAt) public faucetAvailableAt;

    error NotOwner();
    error FaucetCooldown(uint64 availableAt);

    /// @notice Creates a configurable test token.
    /// @param name_ ERC20 name.
    /// @param symbol_ ERC20 symbol.
    /// @param decimals_ ERC20 decimals.
    /// @param owner_ Address authorized to call `mint`.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address owner_) {
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _tokenDecimals = decimals_;
        owner = owner_;
    }

    /// @notice Returns the token name.
    /// @return Token name.
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @notice Returns the token symbol.
    /// @return Token symbol.
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @notice Returns the number of decimal places.
    /// @return Token decimals.
    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    /// @notice Mints test tokens to an account.
    /// @param to Recipient account.
    /// @param amount Amount in the token's smallest unit.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Mints the test faucet allocation to the caller.
    /// @dev MockERC20 grants 1,000 whole tokens per address per hour.
    function faucet() external virtual {
        uint64 availableAt = faucetAvailableAt[msg.sender];
        if (availableAt != 0 && block.timestamp < availableAt) {
            revert FaucetCooldown(availableAt);
        }

        faucetAvailableAt[msg.sender] = uint64(block.timestamp + 1 hours);
        _mint(msg.sender, _faucetAmount());
    }

    function _faucetAmount() internal view virtual returns (uint256) {
        return 1_000 * (10 ** uint256(_tokenDecimals));
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
}
