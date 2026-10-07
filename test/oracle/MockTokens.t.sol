// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {TestUSDC} from "../../src/mocks/TestUSDC.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MockTokensTest is Test {
    TestUSDC internal usdc;
    MockERC20 internal token;

    address internal alice;
    address internal bob;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.warp(1_700_000_000);
        usdc = new TestUSDC(address(this));
        token = new MockERC20("Test MON", "tMON", 18, address(this));
    }

    function test_metadata() public view {
        assertEq(usdc.name(), "Test USDC");
        assertEq(usdc.symbol(), "tUSDC");
        assertEq(usdc.decimals(), 6);
        assertEq(token.name(), "Test MON");
        assertEq(token.symbol(), "tMON");
        assertEq(token.decimals(), 18);
    }

    function test_mint_ownerOnly() public {
        usdc.mint(alice, 1e6);
        token.mint(alice, 1e18);
        assertEq(usdc.balanceOf(alice), 1e6);
        assertEq(token.balanceOf(alice), 1e18);

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        usdc.mint(alice, 1);

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.mint(alice, 1);
    }

    function test_usdc_faucet_hourlyLimit() public {
        vm.prank(alice);
        usdc.faucet();
        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertEq(usdc.lastFaucet(alice), block.timestamp);

        vm.prank(alice);
        vm.expectRevert(TestUSDC.FaucetCooldown.selector);
        usdc.faucet();

        vm.warp(block.timestamp + 1 hours - 1);
        vm.prank(alice);
        vm.expectRevert(TestUSDC.FaucetCooldown.selector);
        usdc.faucet();

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        usdc.faucet();
        assertEq(usdc.balanceOf(alice), 20_000e6);
    }

    function test_mock_faucet_hourlyLimit_and_decimals() public {
        MockERC20 t6 = new MockERC20("Six", "SIX", 6, address(this));
        vm.prank(alice);
        token.faucet();
        assertEq(token.balanceOf(alice), 1_000e18);

        vm.prank(alice);
        vm.expectRevert(MockERC20.FaucetCooldown.selector);
        token.faucet();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        token.faucet();
        assertEq(token.balanceOf(alice), 2_000e18);

        vm.prank(bob);
        t6.faucet();
        assertEq(t6.balanceOf(bob), 1_000e6);
    }

    function test_usdc_permit() public {
        uint256 pk = 0xA11CE;
        address owner_ = vm.addr(pk);
        usdc.mint(owner_, 500e6);

        uint256 value = 150e6;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = usdc.nonces(owner_);
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner_, bob, value, nonce, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        usdc.permit(owner_, bob, value, deadline, v, r, s);
        assertEq(usdc.allowance(owner_, bob), value);
        assertEq(usdc.nonces(owner_), nonce + 1);

        vm.prank(bob);
        usdc.transferFrom(owner_, bob, value);
        assertEq(usdc.balanceOf(bob), value);
        assertEq(usdc.balanceOf(owner_), 350e6);
    }

    function test_usdc_permit_expired() public {
        uint256 pk = 0xB0B;
        address owner_ = vm.addr(pk);
        uint256 deadline = block.timestamp;
        vm.warp(block.timestamp + 1);
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner_, bob, uint256(1), uint256(0), deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.expectRevert(bytes4(keccak256("PermitExpired()")));
        usdc.permit(owner_, bob, 1, deadline, v, r, s);
    }

    function test_usdc_permit_invalidSigner() public {
        uint256 pk = 0xA11CE;
        address owner_ = vm.addr(pk);
        uint256 otherPk = 0xB0B;
        uint256 deadline = block.timestamp + 1;
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner_, bob, uint256(1), uint256(0), deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherPk, digest);
        vm.expectRevert(bytes4(keccak256("InvalidPermit()")));
        usdc.permit(owner_, bob, 1, deadline, v, r, s);
    }
}
