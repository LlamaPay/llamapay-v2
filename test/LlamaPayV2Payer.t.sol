// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/LlamaPayV2Factory.sol";
import "../src/LlamaPayV2Payer.sol";
import "./LlamaToken.sol";
import "./AlpacaToken.sol";

contract LlamaPayV2PayerTest is Test {
    LlamaPayV2Factory public llamaPayV2Factory;
    LlamaPayV2Payer public llamaPayV2Payer;
    LlamaToken public llamaToken;
    AlpacaToken public alpacaToken;

    address public immutable alice = address(1);
    address public immutable bob = address(2);
    address public immutable steve = address(3);

    function setUp() public {
        llamaPayV2Factory = new LlamaPayV2Factory();
        llamaToken = new LlamaToken();
        llamaToken.mint(alice, 20000e18);
        vm.prank(alice);
        llamaPayV2Payer = LlamaPayV2Payer(
            llamaPayV2Factory.createLlamaPayContract()
        );
        vm.prank(alice);
        llamaToken.approve(address(llamaPayV2Payer), 10000e18);
        vm.prank(alice);
        llamaPayV2Payer.deposit(address(llamaToken), 10000e18);
    }

    function testDeposit() public {
        vm.prank(alice);
        llamaToken.approve(address(llamaPayV2Payer), 10000e18);
        vm.prank(alice);
        llamaPayV2Payer.deposit(address(llamaToken), 10000e18);
    }

    function testWithdrawPayer() public {
        vm.prank(alice);
        llamaPayV2Payer.withdrawPayer(address(llamaToken), alice, 1000e20);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(balance, 9000e20);
    }

    function testCreateStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.01 * 1e20);
        (, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(totalPaidPerSec, 0.01 * 1e20);
        assertEq(bob, llamaPayV2Payer.ownerOf(0));
    }

    function testCancelStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.01 * 1e20);
        vm.prank(alice);
        llamaPayV2Payer.cancelStream(0);
    }

    function testPauseStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.prank(alice);
        llamaPayV2Payer.pauseStream(0);
        (, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(totalPaidPerSec, 0);
        assertEq(bob, llamaPayV2Payer.ownerOf(0));
    }

    function testResumeStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.prank(alice);
        llamaPayV2Payer.pauseStream(0);
        vm.prank(alice);
        llamaPayV2Payer.resumeStream(0);
        (, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(totalPaidPerSec, 0.001 * 1e20);
    }

    function testWithdraw() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.warp(1000000);
        vm.prank(bob);
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
    }

    function testWhitelistDeny() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.warp(1000000);
        vm.prank(steve);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
    }

    function testWhitelistApprove() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.warp(1000000);
        vm.prank(bob);
        llamaPayV2Factory.approveWithdrawalWhitelist(steve);
        vm.prank(steve);
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
    }

    function testWithdrawDeny() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.warp(100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AMOUNT_NOT_AVAILABLE()"));
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
    }

    function testWhitelistRevoke() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.warp(1000000);
        vm.prank(bob);
        llamaPayV2Factory.approveWithdrawalWhitelist(steve);
        vm.prank(steve);
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
        vm.prank(bob);
        llamaPayV2Factory.revokeWithdrawalWhitelist(steve);
        vm.prank(steve);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
    }

    function testDenyBurnedWithdraw() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.warp(1000000);
        vm.prank(alice);
        llamaPayV2Payer.cancelStream(0);
        vm.prank(steve);
        vm.expectRevert("NOT_MINTED");
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
    }

    function testRedirect() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.prank(bob);
        llamaPayV2Factory.setRedirect(steve);
        vm.warp(1000000);
        vm.prank(bob);
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
        assertEq(100 * 1e18, llamaToken.balanceOf(steve));
    }

    function testResetRedirect() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.prank(bob);
        llamaPayV2Factory.setRedirect(steve);
        vm.warp(1000000);
        vm.prank(bob);
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
        assertEq(100 * 1e18, llamaToken.balanceOf(steve));
        vm.prank(bob);
        llamaPayV2Factory.resetRedirect();
        vm.prank(bob);
        llamaPayV2Payer.withdraw(0, 300 * 1e20);
        assertEq(300 * 1e18, llamaToken.balanceOf(bob));
    }

    function testOnlyOwnerCanCreateStream() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
    }

    function testOnlyOwnerCanCancelStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.cancelStream(0);
    }

    function testOnlyOwnerCanPauseStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.pauseStream(0);
    }

    function testOnlyOwnerCanResumeStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.resumeStream(0);
    }

    function testPayerWhitelistApprove() external {
        vm.prank(alice);
        llamaPayV2Payer.approvePayerWhitelist(bob);
        vm.prank(bob);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
    }

    function testPayerWhitelistDeny() external {
        vm.prank(alice);
        llamaPayV2Payer.approvePayerWhitelist(bob);
        vm.prank(bob);
        llamaPayV2Payer.createStream(address(llamaToken), bob, 0.001 * 1e20);
        vm.prank(alice);
        llamaPayV2Payer.revokePayerWhitelist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.createStream(address(llamaToken), steve, 0.001 * 1e20);
    }

    function testCannotDoAnythingIfDivisorIsZero() external {
        vm.prank(alice);
        llamaPayV2Payer.createStream(address(alpacaToken), bob, 0.001 * 1e20);
        vm.prank(alice);
        vm.expectRevert(bytes("NH{q"));
        llamaPayV2Payer.withdraw(0, 0);
        vm.prank(alice);
        vm.expectRevert(bytes("NH{q"));
        llamaPayV2Payer.withdrawPayer(address(alpacaToken), alice, 0);
    }
}
