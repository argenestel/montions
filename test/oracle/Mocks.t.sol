// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {TestUSDC} from "../../src/mocks/TestUSDC.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MocksTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    TestUSDC internal usdc;
    MockERC20 internal token18;
    MockERC20 internal token8;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new TestUSDC(owner);
        token18 = new MockERC20("Test MON", "tMON", 18, owner);
        token8 = new MockERC20("Eight", "EIGHT", 8, owner);
    }

    function test_usdc_metadata() public view {
        assertEq(usdc.name(), "Test USDC");
        assertEq(usdc.symbol(), "tUSDC");
        assertEq(usdc.decimals(), 6);
    }

    function test_usdc_mint_ownerOnly() public {
        usdc.mint(alice, 1e6);
        assertEq(usdc.balanceOf(alice), 1e6);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        usdc.mint(alice, 1);
    }

    function test_usdc_faucet_limitAndCooldown() public {
        vm.prank(alice);
        usdc.faucet();
        assertEq(usdc.balanceOf(alice), 10_000e6);

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

    function test_usdc_permit() public {
        uint256 pk = 0xBEEF;
        address user = vm.addr(pk);
        usdc.mint(user, 1_000e6);

        address spender = address(0x5);
        uint256 value = 250e6;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = usdc.nonces(user);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, user, spender, value, nonce, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        usdc.permit(user, spender, value, deadline, v, r, s);

        assertEq(usdc.allowance(user, spender), value);
        assertEq(usdc.nonces(user), nonce + 1);

        vm.prank(spender);
        usdc.transferFrom(user, spender, value);
        assertEq(usdc.balanceOf(spender), value);
        assertEq(usdc.balanceOf(user), 1_000e6 - value);
    }

    function test_usdc_permit_expired() public {
        uint256 pk = 0xBEEF;
        address user = vm.addr(pk);
        uint256 deadline = block.timestamp;
        vm.warp(deadline + 1);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, user, address(this), 1, 0, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.expectRevert(bytes4(keccak256("PermitExpired()")));
        usdc.permit(user, address(this), 1, deadline, v, r, s);
    }

    function test_mock_metadataAndFaucetAmount() public {
        assertEq(token18.name(), "Test MON");
        assertEq(token18.symbol(), "tMON");
        assertEq(token18.decimals(), 18);
        assertEq(token8.decimals(), 8);

        vm.prank(alice);
        token18.faucet();
        assertEq(token18.balanceOf(alice), 1_000e18);

        vm.prank(alice);
        token8.faucet();
        assertEq(token8.balanceOf(alice), 1_000 * 10 ** 8);
    }

    function test_mock_faucet_cooldownAndMintOwnerOnly() public {
        vm.prank(alice);
        token18.faucet();
        vm.prank(alice);
        vm.expectRevert(MockERC20.FaucetCooldown.selector);
        token18.faucet();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        token18.faucet();
        assertEq(token18.balanceOf(alice), 2_000e18);

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token18.mint(alice, 1);
    }
}
