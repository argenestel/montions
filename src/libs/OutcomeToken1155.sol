// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMontionsBook} from "../interfaces/IMontionsBook.sol";

/// @title OutcomeToken1155
/// @notice Internal ERC1155 accounting for YES and NO outcome tokens.
/// @dev The Book deliberately keeps the public ERC1155 wrappers in
///      `MontionsBook`. Internal mint, burn, and transfer operations emit the
///      standard events but never call a receiver hook, which keeps matching
///      free of arbitrary external calls. User initiated transfers can call
///      `_checkOutcomeReceiver` after their state changes.
abstract contract OutcomeToken1155 {
    mapping(address account => mapping(uint256 id => uint256 amount)) internal _outcomeBalances;
    mapping(uint256 id => uint256 amount) internal _outcomeTotalSupplies;
    mapping(address account => mapping(address operator => bool)) internal _outcomeApprovals;

    /// @notice Emitted when an outcome token amount changes hands.
    event TransferSingle(
        address indexed operator, address indexed from, address indexed to, uint256 id, uint256 amount
    );

    /// @notice Emitted when a batch of outcome tokens changes hands.
    event TransferBatch(
        address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] amounts
    );

    /// @notice Emitted when an operator approval changes.
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);

    /// @notice Recipient cannot be the zero address.
    error TransferToZeroAddress();

    /// @notice Recipient contract does not implement the ERC1155 receiver interface.
    error TransferToNonERC1155ReceiverImplementer();

    /// @notice An account balance or total supply would overflow.
    error OutcomeBalanceOverflow();

    /// @notice Outcome-token id and amount arrays have different lengths.
    error OutcomeArrayLengthMismatch();

    /// @notice Returns an account's internal balance for an outcome id.
    /// @param account Account whose balance is queried.
    /// @param id Outcome token id.
    /// @return amount Internal balance.
    function _outcomeBalance(address account, uint256 id) internal view returns (uint256 amount) {
        return _outcomeBalances[account][id];
    }

    /// @notice Returns the internal total supply for an outcome id.
    /// @param id Outcome token id.
    /// @return amount Total supply.
    function _outcomeSupply(uint256 id) internal view returns (uint256 amount) {
        return _outcomeTotalSupplies[id];
    }

    /// @notice Returns whether an operator is approved for an account.
    /// @param account Account granting approval.
    /// @param operator Operator being checked.
    /// @return approved True when the operator may transfer the account's tokens.
    function _outcomeApproved(address account, address operator) internal view returns (bool approved) {
        return _outcomeApprovals[account][operator];
    }

    /// @notice Mints outcome tokens without invoking an ERC1155 receiver hook.
    /// @param to Recipient account.
    /// @param id Outcome token id.
    /// @param amount Number of tokens to mint.
    function _mintOutcome(address to, uint256 id, uint256 amount) internal virtual {
        if (to == address(0)) revert TransferToZeroAddress();

        uint256 oldBalance = _outcomeBalances[to][id];
        uint256 newBalance;
        unchecked {
            newBalance = oldBalance + amount;
        }
        if (newBalance < oldBalance) revert OutcomeBalanceOverflow();

        uint256 oldSupply = _outcomeTotalSupplies[id];
        uint256 newSupply;
        unchecked {
            newSupply = oldSupply + amount;
        }
        if (newSupply < oldSupply) revert OutcomeBalanceOverflow();

        _outcomeBalances[to][id] = newBalance;
        _outcomeTotalSupplies[id] = newSupply;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
    }

    /// @notice Burns outcome tokens without invoking an ERC1155 receiver hook.
    /// @param from Account whose tokens are burned.
    /// @param id Outcome token id.
    /// @param amount Number of tokens to burn.
    function _burnOutcome(address from, uint256 id, uint256 amount) internal virtual {
        uint256 oldBalance = _outcomeBalances[from][id];
        if (oldBalance < amount) revert IMontionsBook.InsufficientTokens();

        uint256 oldSupply = _outcomeTotalSupplies[id];
        // A valid balance cannot exceed total supply. Keep this guard explicit
        // so a malformed derived contract cannot underflow total supply.
        if (oldSupply < amount) revert IMontionsBook.InsufficientTokens();

        _outcomeBalances[from][id] = oldBalance - amount;
        _outcomeTotalSupplies[id] = oldSupply - amount;
        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    /// @notice Transfers outcome tokens without invoking an ERC1155 receiver hook.
    /// @param from Source account.
    /// @param to Destination account.
    /// @param id Outcome token id.
    /// @param amount Number of tokens to transfer.
    function _transferOutcome(address from, address to, uint256 id, uint256 amount) internal virtual {
        if (to == address(0)) revert TransferToZeroAddress();

        uint256 oldFromBalance = _outcomeBalances[from][id];
        if (oldFromBalance < amount) revert IMontionsBook.InsufficientTokens();

        if (from == to) {
            emit TransferSingle(msg.sender, from, to, id, amount);
            return;
        }

        uint256 oldToBalance = _outcomeBalances[to][id];
        uint256 newToBalance;
        unchecked {
            newToBalance = oldToBalance + amount;
        }
        if (newToBalance < oldToBalance) revert OutcomeBalanceOverflow();

        _outcomeBalances[from][id] = oldFromBalance - amount;
        _outcomeBalances[to][id] = newToBalance;
        emit TransferSingle(msg.sender, from, to, id, amount);
    }

    /// @notice Transfers a batch without invoking a receiver hook.
    /// @dev Intended for the user-facing safe batch wrapper, which calls the receiver separately.
    function _transferOutcomeBatch(address from, address to, uint256[] memory ids, uint256[] memory amounts)
        internal
        virtual
    {
        if (to == address(0)) revert TransferToZeroAddress();
        if (ids.length != amounts.length) revert OutcomeArrayLengthMismatch();

        for (uint256 i; i < ids.length; ++i) {
            uint256 oldFromBalance = _outcomeBalances[from][ids[i]];
            uint256 amount = amounts[i];
            if (oldFromBalance < amount) revert IMontionsBook.InsufficientTokens();
            if (from == to) continue;

            uint256 oldToBalance = _outcomeBalances[to][ids[i]];
            uint256 newToBalance;
            unchecked {
                newToBalance = oldToBalance + amount;
            }
            if (newToBalance < oldToBalance) revert OutcomeBalanceOverflow();
            _outcomeBalances[from][ids[i]] = oldFromBalance - amount;
            _outcomeBalances[to][ids[i]] = newToBalance;
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);
    }

    /// @notice Records an ERC1155 operator approval and emits its standard event.
    /// @param account Account granting approval.
    /// @param operator Operator being approved or revoked.
    /// @param approved Whether the operator is approved.
    function _setOutcomeApproval(address account, address operator, bool approved) internal virtual {
        _outcomeApprovals[account][operator] = approved;
        emit ApprovalForAll(account, operator, approved);
    }

    /// @notice Records approval for the current caller.
    /// @param operator Operator being approved or revoked.
    /// @param approved Whether the operator is approved.
    function _setOutcomeApproval(address operator, bool approved) internal virtual {
        _setOutcomeApproval(msg.sender, operator, approved);
    }

    /// @notice Calls an ERC1155 receiver after a user initiated transfer.
    /// @dev This function is intentionally separate from `_transferOutcome` so
    ///      matching, split, merge, and settlement can remain hook-free.
    /// @param from Source account.
    /// @param to Destination account.
    /// @param id Outcome token id.
    /// @param amount Number of tokens transferred.
    /// @param data Receiver callback data.
    function _checkOutcomeReceiver(address from, address to, uint256 id, uint256 amount, bytes memory data)
        internal
        virtual
    {
        if (to.code.length == 0) return;

        bytes4 selector = 0xf23a6e61; // onERC1155Received(address,address,uint256,uint256,bytes)
        (bool success, bytes memory result) =
            to.call(abi.encodeWithSelector(selector, msg.sender, from, id, amount, data));

        if (!success) {
            if (result.length != 0) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            revert TransferToNonERC1155ReceiverImplementer();
        }
        if (result.length < 32 || abi.decode(result, (bytes4)) != selector) {
            revert TransferToNonERC1155ReceiverImplementer();
        }
    }

    /// @notice Calls an ERC1155 batch receiver after a user initiated transfer.
    /// @param from Source account.
    /// @param to Destination account.
    /// @param ids Outcome token ids.
    /// @param amounts Token amounts.
    /// @param data Receiver callback data.
    function _checkOutcomeBatchReceiver(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual {
        if (to.code.length == 0) return;

        bytes4 selector = 0xbc197c81; // onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)
        (bool success, bytes memory result) =
            to.call(abi.encodeWithSelector(selector, msg.sender, from, ids, amounts, data));
        if (!success) {
            if (result.length != 0) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            revert TransferToNonERC1155ReceiverImplementer();
        }
        if (result.length < 32 || abi.decode(result, (bytes4)) != selector) {
            revert TransferToNonERC1155ReceiverImplementer();
        }
    }
}
