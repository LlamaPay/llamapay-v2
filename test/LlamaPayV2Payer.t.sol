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
        llamaToken.mint(alice, 10000 * 1e18);
        vm.startPrank(alice);
        llamaPayV2Payer = LlamaPayV2Payer(
            llamaPayV2Factory.createLlamaPayContract()
        );
        llamaToken.approve(address(llamaPayV2Payer), 10000 * 1e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000 * 1e18);
        vm.stopPrank();
    }

    // (
    //     uint256 balance,
    //     uint256 totalPaidPerSec,
    //     uint208 divisor,
    //     uint48 lastUpdate
    // ) = llamaPayV2Payer.tokens(address(llamaToken));
    // (
    //     uint208 amountPerSec,
    //     uint48 lastPaid,
    //     address token,
    //     uint48 starts,
    //     uint48 ends,
    //     uint256 redeemable
    // ) = llamaPayV2Payer.streams(0);

    function testDeposit() public {
        llamaToken.mint(alice, 10000 * 1e18);
        vm.startPrank(alice);
        llamaToken.approve(address(llamaPayV2Payer), 10000 * 1e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000 * 1e18);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(balance, 20000 * 1e20);
        assertEq(llamaToken.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function testWithdrawPayer() public {
        vm.startPrank(alice);
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 1000 * 1e18);
        assertEq(llamaToken.balanceOf(alice), 1000 * 1e18);
        vm.stopPrank();
    }

    function testCreateStream() public {
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
            uint48 ends,
            uint256 redeemable
        ) = llamaPayV2Payer.streams(0);
        (, uint256 totalPaidPerSec, , uint48 lastUpdate) = llamaPayV2Payer
            .tokens(address(llamaToken));

        assertEq(amountPerSec, 1 * 1e20);
        assertEq(lastPaid, 1);
        assertEq(token, address(llamaToken));
        assertEq(starts, 1);
        assertEq(ends, 1000);
        assertEq(redeemable, 0);
        assertEq(llamaPayV2Payer.ownerOf(0), bob);

        assertEq(totalPaidPerSec, 1 * 1e20);
        assertEq(lastUpdate, 1);

        vm.stopPrank();
    }

    function testModifyStream() public {
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
        llamaPayV2Payer.modifyStream(0, 2 * 1e20);

        (
            uint208 amountPerSec,
            uint48 lastPaid,
            ,
            ,
            ,
            uint256 redeemable
        ) = llamaPayV2Payer.streams(0);
        (, uint256 totalPaidPerSec, , uint48 lastUpdate) = llamaPayV2Payer
            .tokens(address(llamaToken));

        assertEq(amountPerSec, 2 * 1e20);
        assertEq(lastPaid, 101);
        assertEq(redeemable, 100 * 1e20);

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
        llamaPayV2Payer.stopStream(0);

        (, uint48 lastPaid, , , , uint256 redeemable) = llamaPayV2Payer.streams(
            0
        );
        (, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );

        assertEq(lastPaid, 0);
        assertEq(redeemable, 100 * 1e20);

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
        llamaPayV2Payer.stopStream(0);
        vm.warp(200);
        llamaPayV2Payer.resumeStream(0);

        (, uint48 lastPaid, , , , ) = llamaPayV2Payer.streams(0);
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
        llamaPayV2Payer.stopStream(0);
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
        llamaPayV2Payer.burnStream(0);

        vm.stopPrank();
    }

    function testPayerWhitelist() external {
        vm.prank(alice);
        llamaPayV2Payer.approvePayerWhitelist(bob);
        vm.prank(bob);
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 10 * 1e18);
        assertEq(llamaToken.balanceOf(bob), 10 * 1e18);
        vm.prank(alice);
        llamaPayV2Payer.revokePayerWhitelist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NOT_OWNER_OR_WHITELISTED()"));
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 10 * 1e18);
    }

    function testRedirect() external {
        vm.startPrank(alice);
        vm.warp(1);
        llamaPayV2Factory.setRedirect(bob);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            alice,
            1 * 1e20,
            1,
            1000
        );
        vm.warp(101);
        llamaPayV2Payer.withdraw(0, 50 * 1e18);
        assertEq(llamaToken.balanceOf(bob), 50 * 1e18);
        llamaPayV2Factory.resetRedirect();
        llamaPayV2Payer.withdraw(0, 50 * 1e18);
        assertEq(llamaToken.balanceOf(alice), 50 * 1e18);
        vm.stopPrank();
    }
}
