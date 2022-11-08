// SPDX-License-Identifier: UNLICENSED

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

    function setUp() external {
        llamaPayV2Factory = new LlamaPayV2Factory();
        llamaToken = new LlamaToken();
        llamaToken.mint(alice, 10000 * 1e18);
        vm.startPrank(alice);
        llamaPayV2Payer = LlamaPayV2Payer(
            llamaPayV2Factory.createLlamaPayContract()
        );
        llamaToken.approve(address(llamaPayV2Payer), 10000 * 1e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000 * 1e18);
        vm.stopPrank();
    }

    function testDeposit() external {
        llamaToken.mint(alice, 10000 * 1e18);
        vm.startPrank(alice);
        llamaToken.approve(address(llamaPayV2Payer), 10000 * 1e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000 * 1e18);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(balance, 20000 * 1e20);
        assertEq(llamaToken.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function testWithdrawPayer() external {
        vm.startPrank(alice);
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 1000 * 1e18);
        assertEq(llamaToken.balanceOf(alice), 1000 * 1e18);
        vm.stopPrank();
    }

    function testCreateStream() external {
        vm.startPrank(alice);
        vm.warp(1);

        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1 * 1e20,
            1,
            1000
        );

        (
            uint208 amountPerSec,
            uint48 lastPaid,
            address token,
            uint48 starts,
            uint48 ends
        ) = llamaPayV2Payer.streams(0);
        (, uint256 totalPaidPerSec, , uint48 lastUpdate) = llamaPayV2Payer
            .tokens(address(llamaToken));

        assertEq(amountPerSec, 1 * 1e20);
        assertEq(lastPaid, 1);
        assertEq(token, address(llamaToken));
        assertEq(starts, 1);
        assertEq(ends, 1000);
        assertEq(llamaPayV2Payer.redeemables(0), 0);
        assertEq(llamaPayV2Payer.ownerOf(0), bob);

        assertEq(totalPaidPerSec, 1 * 1e20);
        assertEq(lastUpdate, 1);

        vm.stopPrank();
    }

    function testCreateStreamWithStartBeforeCreation() external {
        vm.startPrank(alice);
        vm.warp(11);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1 * 1e20,
            1,
            1000
        );
        assertEq(llamaPayV2Payer.redeemables(0), 10 * 1e20);
        vm.stopPrank();
    }

    function testModifyStream() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1 * 1e20,
            1,
            1000
        );
        vm.warp(101);
        llamaPayV2Payer.modifyStream(0, 2 * 1e20, 1000, false);

        (uint208 amountPerSec, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(
            0
        );
        (, uint256 totalPaidPerSec, , uint48 lastUpdate) = llamaPayV2Payer
            .tokens(address(llamaToken));

        assertEq(amountPerSec, 2 * 1e20);
        assertEq(lastPaid, 101);
        assertEq(llamaPayV2Payer.redeemables(0), 100 * 1e20);

        assertEq(totalPaidPerSec, 2 * 1e20);
        assertEq(lastUpdate, 101);

        vm.stopPrank();
    }

    function testStopStream() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1 * 1e20,
            1,
            1000
        );
        vm.warp(101);
        llamaPayV2Payer.stopStream(0, false);

        (, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(0);
        (, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );

        assertEq(lastPaid, 0);
        assertEq(llamaPayV2Payer.redeemables(0), 100 * 1e20);

        assertEq(totalPaidPerSec, 0);

        vm.stopPrank();
    }

    function testResumeStream() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1 * 1e20,
            1,
            1000
        );
        vm.warp(101);
        llamaPayV2Payer.stopStream(0, false);
        vm.warp(200);
        llamaPayV2Payer.resumeStream(0);

        (, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(0);
        (, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );

        assertEq(lastPaid, 200);
        assertEq(totalPaidPerSec, 1 * 1e20);

        vm.stopPrank();
    }

    function testBurnStream() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1 * 1e20,
            1,
            1000
        );
        vm.warp(101);
        llamaPayV2Payer.stopStream(0, false);
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
        llamaPayV2Payer.burnStream(0);

        vm.stopPrank();
    }

    function testUpdateStream() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1000
        );
        vm.warp(101);
        llamaPayV2Payer.updateStream(0);

        (, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(0);
        assertEq(lastPaid, 101);
        assertEq(llamaPayV2Payer.redeemables(0), 100 * 1e20);

        vm.stopPrank();
    }

    function testStreamWithCustomStart() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            100,
            1000
        );
        (uint256 balance, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(balance, 10000 * 1e20);
        assertEq(totalPaidPerSec, 1 * 1e20);
        vm.warp(110);
        llamaPayV2Payer.updateStream(0);
        (balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(llamaPayV2Payer.redeemables(0), 10 * 1e20);
        assertEq(balance, 9990 * 1e20);
        vm.stopPrank();
    }

    function testStreamWithCustomEnd() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            101,
            1101
        );
        vm.warp(2000);
        llamaPayV2Payer.updateStream(0);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(llamaPayV2Payer.redeemables(0), 1000 * 1e20);
        assertEq(balance, 9000 * 1e20);
        vm.stopPrank();
    }

    function testStreamCustomStartAndEnd() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            101,
            1101
        );
        vm.warp(2000);
        llamaPayV2Payer.updateStream(0);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(llamaPayV2Payer.redeemables(0), 1000 * 1e20);
        assertEq(balance, 9000 * 1e20);
        vm.stopPrank();
    }

    function testStreamInactive() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1101
        );
        vm.warp(501);
        llamaPayV2Payer.stopStream(0, false);
        vm.warp(2000);
        llamaPayV2Payer.updateStream(0);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(llamaPayV2Payer.redeemables(0), 500 * 1e20);
        assertEq(balance, 9500 * 1e20);
        vm.stopPrank();
    }

    function testCantWithdrawVestedAmounts() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            10000000000
        );
        vm.warp(9500);
        /// Will revert because vested 9500 LLAMA and trying to withdraw 1000 LLAMA.
        /// Beginning balance is only 10000
        vm.expectRevert();
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 1000 * 1e18);
        vm.stopPrank();
    }

    function testCantWithdrawIfNotWhitelisted() external {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 1 * 1e18);
    }

    function testCantWithdrawMoreThanAvailable() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1000000
        );
        vm.warp(501);
        vm.expectRevert();
        llamaPayV2Payer.withdraw(0, 1000 * 1e18);
        vm.stopPrank();
    }

    function testCantModifyUnlessWhitelisted() external {
        vm.prank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1000000
        );
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.modifyStream(0, 200 * 1e20, 1000000, false);
    }

    function testCantStopIfStopped() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1000000
        );
        llamaPayV2Payer.stopStream(0, false);
        vm.expectRevert(abi.encodeWithSignature("INACTIVE_STREAM()"));
        llamaPayV2Payer.stopStream(0, false);
        vm.stopPrank();
    }

    function testCantResumeActiveStream() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1000000
        );
        vm.expectRevert(abi.encodeWithSignature("ACTIVE_STREAM()"));
        llamaPayV2Payer.resumeStream(0);
        vm.stopPrank();
    }

    function testCantResumeAfterStreamEnded() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            100
        );
        llamaPayV2Payer.stopStream(0, false);
        vm.warp(100);
        vm.expectRevert(abi.encodeWithSignature("STREAM_HAS_ENDED()"));
        llamaPayV2Payer.resumeStream(0);
        vm.stopPrank();
    }

    function testCantResumeIfInDebt() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            15000
        );
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            15000
        );
        llamaPayV2Payer.stopStream(1, false);
        vm.warp(11000);
        vm.expectRevert(abi.encodeWithSignature("PAYER_IN_DEBT()"));
        llamaPayV2Payer.resumeStream(1);
        vm.stopPrank();
    }

    function testCantBurnIfActive() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            15000
        );
        vm.expectRevert(
            abi.encodeWithSignature("STREAM_ACTIVE_OR_REDEEMABLE()")
        );
        llamaPayV2Payer.burnStream(0);
        vm.stopPrank();
    }

    function testCantBurnIfRedeemable() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            15000
        );
        vm.warp(1000);
        llamaPayV2Payer.stopStream(0, false);
        vm.expectRevert(
            abi.encodeWithSignature("STREAM_ACTIVE_OR_REDEEMABLE()")
        );
        llamaPayV2Payer.burnStream(0);
        vm.stopPrank();
    }

    function testUpdateStreamBeforeStreamStart() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            100,
            1000
        );
        vm.warp(51);
        llamaPayV2Payer.updateStream(0);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        (, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(0);
        assertEq(balance, 10000 * 1e20);
        assertEq(llamaPayV2Payer.redeemables(0), 0);
        assertEq(lastPaid, 51);
        vm.stopPrank();
    }

    function testRedirect() external {
        vm.startPrank(alice);
        vm.warp(11);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1000
        );
        llamaPayV2Payer.addRedirectStream(0, bob);
        vm.warp(101);
        llamaPayV2Payer.withdraw(0, 50 * 1e18);
        assertEq(llamaToken.balanceOf(bob), 50 * 1e18);
        vm.warp(151);
        llamaPayV2Payer.removeRedirectStream(0);
        llamaPayV2Payer.withdraw(0, 50 * 1e18);
        assertEq(llamaToken.balanceOf(alice), 50 * 1e18);
        vm.stopPrank();
    }

    function testPayerWhitelist() external {
        vm.prank(alice);
        llamaPayV2Payer.addPayerWhitelist(bob);
        vm.prank(bob);
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 10 * 1e18);
        assertEq(llamaToken.balanceOf(bob), 10 * 1e18);
        vm.prank(alice);
        llamaPayV2Payer.removePayerWhitelist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 10 * 1e18);
    }

    function testStreamWhitelist() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1000
        );
        llamaPayV2Payer.addStreamWhitelist(0, bob);
        vm.stopPrank();
        vm.warp(101);
        vm.prank(bob);
        llamaPayV2Payer.withdraw(0, 10 * 1e18);
        vm.prank(alice);
        llamaPayV2Payer.removeStreamWhitelist(0, bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.withdraw(0, 10 * 1e18);
        vm.stopPrank();
    }

    function testDebt() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            50000
        );
        vm.warp(20000);
        llamaPayV2Payer.updateStream(0);
        (uint256 balance, , , uint256 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        (, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(0);
        assertEq(balance, 0);
        assertEq(lastUpdate, 10000);
        assertEq(lastPaid, 10000);
        assertEq(llamaPayV2Payer.redeemables(0), 10000 * 1e20);
        vm.stopPrank();
    }

    function testDebtModifyStream() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            50000
        );
        vm.warp(20000);
        llamaPayV2Payer.modifyStream(0, 2 * 1e20, 50000, true);
        (uint256 balance, , , uint256 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        (, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(0);
        assertEq(balance, 0);
        assertEq(lastUpdate, 10000);
        assertEq(lastPaid, 20000);
        assertEq(llamaPayV2Payer.redeemables(0), 10000 * 1e20);
        assertEq(10000 * 1e20, llamaPayV2Payer.debts(0));
        vm.stopPrank();
    }

    function testDebtStopStream() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            50000
        );
        vm.warp(20000);
        llamaPayV2Payer.stopStream(0, true);
        (uint256 balance, , , uint256 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        (, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(0);
        assertEq(balance, 0);
        assertEq(lastUpdate, 10000);
        assertEq(lastPaid, 0);
        assertEq(llamaPayV2Payer.redeemables(0), 10000 * 1e20);
        assertEq(10000 * 1e20, llamaPayV2Payer.debts(0));
        vm.stopPrank();
    }

    function testWithdrawableNotStartedAndEnded() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            5000
        );
        vm.warp(6000);
        (
            uint256 lastUpdate,
            uint256 debt,
            uint256 withdrawableAmount
        ) = llamaPayV2Payer.withdrawable(0);
        llamaPayV2Payer.updateStream(0);
        assertEq(lastUpdate, 6000);
        assertEq(debt, 0);
        assertEq(withdrawableAmount, 5000 * 1e18);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            6000,
            15000
        );
        vm.warp(12000);
        (lastUpdate, debt, withdrawableAmount) = llamaPayV2Payer.withdrawable(
            1
        );
        assertEq(lastUpdate, 11000);
        assertEq(debt, 1000 * 1e18);
        assertEq(withdrawableAmount, 5000 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawableStartedButNotUpdated() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            10000
        );
        vm.warp(5000);
        (
            uint256 lastUpdate,
            uint256 debt,
            uint256 withdrawableAmount
        ) = llamaPayV2Payer.withdrawable(0);
        assertEq(withdrawableAmount, 5000 * 1e18);
        llamaPayV2Payer.stopStream(0, false);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            5000,
            15000
        );
        vm.warp(11000);
        (lastUpdate, debt, withdrawableAmount) = llamaPayV2Payer.withdrawable(
            1
        );
        assertEq(lastUpdate, 10000);
        assertEq(debt, 1000 * 1e18);
        assertEq(withdrawableAmount, 5000 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawableStreamEnded() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            5000
        );
        llamaPayV2Payer.updateStream(0);
        vm.warp(5500);
        (
            uint256 lastUpdate,
            uint256 debt,
            uint256 withdrawableAmount
        ) = llamaPayV2Payer.withdrawable(0);
        assertEq(withdrawableAmount, 5000 * 1e18);
        llamaPayV2Payer.updateStream(0);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        vm.warp(6000);
        assertEq(balance, 5000 * 1e20);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            5000,
            20000
        );
        llamaPayV2Payer.updateStream(1);
        vm.warp(12000);
        (lastUpdate, debt, withdrawableAmount) = llamaPayV2Payer.withdrawable(
            1
        );
        assertEq(lastUpdate, 10000);
        assertEq(debt, 2000 * 1e18);
        assertEq(withdrawableAmount, 5000 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawableNormalStream() external {
        vm.startPrank(alice);
        vm.warp(100);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            5000
        );
        llamaPayV2Payer.updateStream(0);
        vm.warp(3000);
        (
            uint256 lastUpdate,
            uint256 debt,
            uint256 withdrawableAmount
        ) = llamaPayV2Payer.withdrawable(0);
        assertEq(lastUpdate, 3000);
        assertEq(0, debt);
        assertEq(withdrawableAmount, 3000 * 1e18);
        llamaPayV2Payer.stopStream(0, false);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            3000,
            100000
        );
        llamaPayV2Payer.updateStream(1);
        vm.warp(15000);
        (lastUpdate, debt, withdrawableAmount) = llamaPayV2Payer.withdrawable(
            1
        );
        assertEq(lastUpdate, 10000);
        assertEq(debt, 5000 * 1e18);
        assertEq(withdrawableAmount, 7000 * 1e18);
        vm.stopPrank();
    }

    function testRepayDebt() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            100000
        );
        vm.warp(20000);
        llamaPayV2Payer.stopStream(0, true);
        assertEq(llamaPayV2Payer.debts(0), 10000 * 1e20);
        llamaToken.mint(alice, 10000 * 1e18);
        llamaToken.approve(address(llamaPayV2Payer), 10000 * 1e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000 * 1e18);
        llamaPayV2Payer.repayDebt(0, 10000 * 1e20);
        assertEq(llamaPayV2Payer.debts(0), 0);
        assertEq(llamaPayV2Payer.redeemables(0), 20000 * 1e20);
        vm.stopPrank();
    }

    function testCreateStreamWithDebt() external {
        vm.startPrank(alice);
        vm.warp(15000);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            100000000
        );
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(llamaPayV2Payer.redeemables(0), 10000 * 1e20);
        assertEq(llamaPayV2Payer.debts(0), 5000 * 1e20);
        assertEq(balance, 0);
        vm.stopPrank();
    }

    function testCancelDebt() external {
        vm.startPrank(alice);
        vm.warp(15000);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            0,
            100000000
        );
        assertEq(llamaPayV2Payer.debts(0), 5000 * 1e20);
        llamaPayV2Payer.cancelDebt(0);
        assertEq(llamaPayV2Payer.debts(0), 0);
        vm.stopPrank();
    }
}
