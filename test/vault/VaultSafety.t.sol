// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultTestBase} from "./VaultTestBase.sol";
import {MakerVault} from "../../src/MakerVault.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract VaultSafetyTest is VaultTestBase {
    event DepositsPausedSet(bool paused);
    event MaxTotalAssetsSet(uint256 maxTotalAssets);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    function testMaxTotalAssetsConstrainsDepositMintAndErc4626Views() public {
        assertEq(vault.maxTotalAssets(), type(uint256).max);
        uint256 cap = 100 * UNIT;
        vm.expectEmit(false, false, false, true, address(vault));
        emit MaxTotalAssetsSet(cap);
        vault.setMaxTotalAssets(cap);
        assertEq(vault.maxDeposit(ALICE), cap);
        assertEq(vault.maxMint(ALICE), vault.convertToShares(cap));

        _depositVault(ALICE, 60 * UNIT);
        assertEq(vault.maxDeposit(BOB), 40 * UNIT);
        uint256 mintLimit = vault.maxMint(BOB);
        assertEq(mintLimit, vault.convertToShares(40 * UNIT));

        vm.expectRevert(MakerVault.VaultCapExceeded.selector);
        vm.prank(BOB);
        vault.deposit(40 * UNIT + 1, BOB);

        vm.expectRevert(MakerVault.VaultCapExceeded.selector);
        vm.prank(BOB);
        vault.mint(mintLimit + 1, BOB);

        vm.prank(BOB);
        uint256 assetsMinted = vault.mint(mintLimit, BOB);
        assertLe(assetsMinted, 40 * UNIT);
        assertLe(vault.totalAssets(), cap);
        assertEq(vault.maxDeposit(ATTACKER), cap - vault.totalAssets());
    }

    function testLoweringVaultCapBelowNavBlocksDepositsButNotWithdrawals() public {
        _depositVault(ALICE, 50 * UNIT);
        vault.setMaxTotalAssets(25 * UNIT);
        assertEq(vault.maxDeposit(ALICE), 0);
        assertEq(vault.maxMint(ALICE), 0);

        vm.expectRevert(MakerVault.VaultCapExceeded.selector);
        vm.prank(BOB);
        vault.deposit(1, BOB);
        vm.expectRevert(MakerVault.VaultCapExceeded.selector);
        vm.prank(BOB);
        vault.mint(1, BOB);

        vm.prank(ALICE);
        vault.withdraw(10 * UNIT, ALICE, ALICE);
        assertEq(vault.totalAssets(), 40 * UNIT);
        assertEq(vault.maxDeposit(ALICE), 0);
    }

    function testDepositPauseBlocksDepositAndMintButNeverWithdrawals() public {
        _depositVault(ALICE, 100 * UNIT);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DepositsPausedSet(true);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());
        assertEq(vault.maxDeposit(ALICE), 0);
        assertEq(vault.maxMint(ALICE), 0);

        vm.expectRevert(MakerVault.DepositsPaused.selector);
        vm.prank(BOB);
        vault.deposit(UNIT, BOB);
        vm.expectRevert(MakerVault.DepositsPaused.selector);
        vm.prank(BOB);
        vault.mint(1, BOB);

        vm.prank(ALICE);
        vault.withdraw(10 * UNIT, ALICE, ALICE);
        assertEq(vault.totalAssets(), 90 * UNIT);

        vault.setDepositsPaused(false);
        assertFalse(vault.depositsPaused());
        assertGt(vault.maxDeposit(BOB), 0);
        vm.prank(BOB);
        vault.deposit(UNIT, BOB);
    }

    function testVaultOwnershipRequiresTwoStepAndCannotBeRenounced() public {
        vm.expectRevert(MakerVault.TwoStepOwnershipRequired.selector);
        vault.transferOwnership(ALICE);
        vm.expectRevert(MakerVault.OwnershipRenunciationDisabled.selector);
        vault.renounceOwnership();

        vm.prank(ALICE);
        vault.requestOwnershipHandover();
        assertGt(vault.ownershipHandoverExpiresAt(ALICE), block.timestamp);
        vm.expectEmit(true, true, false, true, address(vault));
        emit OwnershipTransferred(address(this), ALICE);
        vault.completeOwnershipHandover(ALICE);
        assertEq(vault.owner(), ALICE);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vault.setMaxTotalAssets(1);
        vm.prank(ALICE);
        vault.setMaxTotalAssets(1);
        assertEq(vault.maxTotalAssets(), 1);
    }

    function testOnlyOwnerCanSetDepositPauseAndVaultCap() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(ALICE);
        vault.setDepositsPaused(true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(ALICE);
        vault.setMaxTotalAssets(0);
    }
}
