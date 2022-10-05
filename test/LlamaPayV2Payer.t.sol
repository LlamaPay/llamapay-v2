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
        vm.startPrank(alice);
        llamaPayV2Payer = LlamaPayV2Payer(
            llamaPayV2Factory.createLlamaPayContract()
        );
        llamaToken.approve(address(llamaPayV2Payer), 10000e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000e18);
        vm.stopPrank();
    }

    function testDeposit() public {
        vm.startPrank(alice);
        llamaToken.approve(address(llamaPayV2Payer), 10000e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000e18);
        vm.stopPrank();
    }

    function testWithdrawPayer() public {
        vm.startPrank(alice);
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 1000e18);
        vm.stopPrank();
    }

    function testCreateStream() public {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            1000
        );
        vm.stopPrank();
    }

    function testCreateStreamWithReason() public {
        vm.startPrank(alice);
        llamaPayV2Payer.createStreamWithReason(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            1000,
            "uwu"
        );
        vm.stopPrank();
    }

    function testCreateStreamWithheldWithReason() public {
        vm.startPrank(alice);
        llamaPayV2Payer.createStreamWithheldWithReason(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            1000,
            0.001 * 1e20,
            "uwu"
        );
        vm.stopPrank();
    }

    function testCreateStreamWithheld() public {
        vm.startPrank(alice);
        llamaPayV2Payer.createStreamWithheld(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            1000,
            0.001 * 1e20
        );
        vm.stopPrank();
    }

    function testStopStream() public {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            1000
        );
        llamaPayV2Payer.stopStream(0);
        vm.stopPrank();
    }

    function testBurnStream() public {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            1000
        );
        llamaPayV2Payer.stopStream(0);
        llamaPayV2Payer.burnStream(0);
        vm.stopPrank();
    }

    function testResumeStream() public {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            1000
        );
        llamaPayV2Payer.stopStream(0);
        llamaPayV2Payer.resumeStream(0);
        vm.stopPrank();
    }

    function testWithdrawNotCustom() public {
        vm.startPrank(alice);
        vm.warp(10);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            1000
        );
        vm.warp(100);
        llamaPayV2Payer.withdraw(0, 0.9 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawCustomStart() public {
        vm.startPrank(alice);
        vm.warp(10);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            100,
            1000
        );
        vm.warp(150);
        llamaPayV2Payer.withdraw(0, 0.5 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawCustomEnd() public {
        vm.startPrank(alice);
        vm.warp(10);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            10,
            60
        );
        vm.warp(150);
        llamaPayV2Payer.withdraw(0, 0.5 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawCustomStartAndEndButYouNeverCallItForSomeReason()
        public
    {
        vm.startPrank(alice);
        vm.warp(10);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.01 * 1e20,
            20,
            60
        );
        vm.warp(70);
        llamaPayV2Payer.withdraw(0, 0.4 * 1e18);
        vm.stopPrank();
    }

    function testWhitelistDeny() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.warp(1000000);
        vm.prank(steve);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
    }

    function testWhitelistApprove() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.warp(1000000);
        vm.prank(bob);
        llamaPayV2Factory.approveWithdrawalWhitelist(steve);
        vm.prank(steve);
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
    }

    function testWithdrawDeny() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.warp(100);
        vm.prank(bob);
        vm.expectRevert(bytes("NH{q"));
        llamaPayV2Payer.withdraw(0, 100 * 1e20);
    }

    function testWhitelistRevoke() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.warp(1000000);
        vm.prank(bob);
        llamaPayV2Factory.approveWithdrawalWhitelist(steve);
        vm.prank(steve);
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
        vm.prank(bob);
        llamaPayV2Factory.revokeWithdrawalWhitelist(steve);
        vm.prank(steve);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
    }

    function testRedirect() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.startPrank(bob);
        llamaPayV2Factory.setRedirect(steve);
        vm.warp(1000000);
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
        assertEq(100 * 1e18, llamaToken.balanceOf(steve));
        vm.stopPrank();
    }

    function testResetRedirect() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.startPrank(bob);
        llamaPayV2Factory.setRedirect(steve);
        vm.warp(1000000);
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
        assertEq(100 * 1e18, llamaToken.balanceOf(steve));
        llamaPayV2Factory.resetRedirect();
        llamaPayV2Payer.withdraw(0, 300 * 1e18);
        assertEq(300 * 1e18, llamaToken.balanceOf(bob));
        vm.stopPrank();
    }

    function testOnlyOwnerCanCreateStream() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
    }

    function testOnlyOwnerCanCancelStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.stopStream(0);
    }

    function testOnlyOwnerCanPauseStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.stopStream(0);
    }

    function testOnlyOwnerCanResumeStream() public {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.resumeStream(0);
    }

    function testPayerWhitelistApprove() external {
        vm.prank(alice);
        llamaPayV2Payer.approvePayerWhitelist(bob);
        vm.prank(bob);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
    }

    function testPayerWhitelistDeny() external {
        vm.prank(alice);
        llamaPayV2Payer.approvePayerWhitelist(bob);
        vm.prank(bob);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            0.001 * 1e20,
            10,
            1000000
        );
        vm.prank(alice);
        llamaPayV2Payer.revokePayerWhitelist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.createStream(
            address(llamaToken),
            steve,
            0.001 * 1e20,
            10,
            1000000
        );
    }
}
