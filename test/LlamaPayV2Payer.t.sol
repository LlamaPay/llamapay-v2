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
        vm.warp(10000);
        llamaPayV2Factory = new LlamaPayV2Factory();
        llamaToken = new LlamaToken();
        alpacaToken = new AlpacaToken();
        llamaToken.mint(alice, 50000 * 1e18);
        llamaToken.mint(bob, 50000 * 1e18);
        alpacaToken.mint(alice, 50000 * 1e18);
        vm.startPrank(alice);
        llamaPayV2Payer = LlamaPayV2Payer(
            llamaPayV2Factory.createLlamaPayContract()
        );
        llamaToken.approve(address(llamaPayV2Payer), 10000 * 1e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000 * 1e18);
        vm.stopPrank();
    }

    function testDeposit() external {
        vm.prank(alice);
        llamaToken.approve(address(llamaPayV2Payer), 10000 * 1e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000 * 1e18);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(llamaToken.balanceOf(alice), 30000 * 1e18);
        assertEq(llamaToken.balanceOf(address(llamaPayV2Payer)), 20000 * 1e18);
        assertEq(balance, 20000 * 1e20);
        vm.stopPrank();
    }

    function testDepositOnBehalf() external {
        vm.prank(bob);
        llamaToken.approve(address(llamaPayV2Payer), 10000 * 1e18);
        llamaPayV2Payer.deposit(address(llamaToken), 10000 * 1e18);
        (uint256 balance, , , ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(llamaToken.balanceOf(address(llamaPayV2Payer)), 20000 * 1e18);
        assertEq(llamaToken.balanceOf(bob), 40000 * 1e18);
        assertEq(balance, 20000 * 1e20);
        vm.stopPrank();
    }

    function testDepositDivisor() external {
        (, , uint208 divisor, ) = llamaPayV2Payer.tokens(address(llamaToken));
        assertEq(divisor, 100);
    }

    function testWithdrawPayer() external {
        vm.startPrank(alice);
        vm.warp(15000);
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 5000 * 1e18);
        (uint256 balance, , , uint48 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(llamaToken.balanceOf(address(llamaPayV2Payer)), 5000 * 1e18);
        assertEq(llamaToken.balanceOf(alice), 45000 * 1e18);
        assertEq(balance, 5000 * 1e20);
        assertEq(lastUpdate, 15000);
        vm.stopPrank();
    }

    function testWithdrawPayerCannotRugPayee() external {
        vm.startPrank(alice);
        llamaPayV2Payer.createStream(
            address(llamaPayV2Payer),
            bob,
            1e20,
            10000,
            1000000
        );
        vm.warp(15000);
        vm.expectRevert();
        llamaPayV2Payer.withdrawPayer(address(llamaPayV2Payer), 7500 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawPayerNotAllowed() external {
        vm.startPrank(steve);
        vm.expectRevert();
        llamaPayV2Payer.withdrawPayer(address(llamaToken), 100 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawPayerAll() external {
        vm.startPrank(alice);
        vm.warp(15000);
        llamaPayV2Payer.withdrawPayerAll(address(llamaToken));
        (uint256 balance, , , uint48 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(llamaToken.balanceOf(address(llamaPayV2Payer)), 0);
        assertEq(llamaToken.balanceOf(alice), 50000 * 1e18);
        assertEq(balance, 0);
        assertEq(lastUpdate, 15000);
        vm.stopPrank();
    }

    function testWithdrawStream() external {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1e20,
            10000,
            10000000
        );
        vm.warp(15000);
        vm.prank(alice);
        llamaPayV2Payer.withdraw(0, 2500 * 1e18);
        vm.prank(bob);
        llamaPayV2Payer.withdraw(0, 2500 * 1e18);
        (uint256 balance, , , uint48 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(llamaToken.balanceOf(address(llamaPayV2Payer)), 5000 * 1e18);
        assertEq(llamaToken.balanceOf(bob), 55000 * 1e18);
        assertEq(balance, 5000 * 1e20);
        assertEq(lastUpdate, 15000);
    }

    function testWithdrawStreamCannotIfNotWhitelist() external {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1e20,
            10000,
            10000000
        );
        vm.warp(15000);
        vm.prank(steve);
        vm.expectRevert();
        llamaPayV2Payer.withdraw(0, 100 * 1e18);
    }

    function testWithdrawAll() external {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1e20,
            10000,
            10000000
        );
        vm.warp(17000);
        vm.prank(bob);
        llamaPayV2Payer.withdrawAll(0);
        (uint256 balance, , , uint48 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(llamaToken.balanceOf(address(llamaPayV2Payer)), 3000 * 1e18);
        assertEq(llamaToken.balanceOf(bob), 57000 * 1e18);
        assertEq(balance, 3000 * 1e20);
        assertEq(lastUpdate, 17000);
    }

    function testWithdrawWithRedirect() external {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1e20,
            10000,
            10000000
        );
        vm.prank(bob);
        llamaPayV2Payer.addRedirectStream(0, steve);
        vm.warp(15000);
        vm.prank(bob);
        llamaPayV2Payer.withdrawWithRedirect(0, 4000 * 1e18);
        (uint256 balance, , , uint48 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(llamaToken.balanceOf(address(llamaPayV2Payer)), 6000 * 1e18);
        assertEq(llamaToken.balanceOf(steve), 4000 * 1e18);
        assertEq(balance, 5000 * 1e20);
        assertEq(lastUpdate, 15000);
    }

    function testWithdrawAllWithRedirect() external {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1e20,
            10000,
            10000000
        );
        vm.prank(bob);
        llamaPayV2Payer.addRedirectStream(0, steve);
        vm.warp(15000);
        vm.prank(bob);
        llamaPayV2Payer.withdrawAllWithRedirect(0);
        (uint256 balance, , , uint48 lastUpdate) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(llamaToken.balanceOf(address(llamaPayV2Payer)), 5000 * 1e18);
        assertEq(llamaToken.balanceOf(steve), 5000 * 1e18);
        assertEq(balance, 5000 * 1e20);
        assertEq(lastUpdate, 15000);
    }

    function testCreateStream() external {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1e20,
            10000,
            10000000
        );
        (
            uint208 amountPerSec,
            uint48 lastPaid,
            address token,
            uint48 starts,
            uint48 ends
        ) = llamaPayV2Payer.streams(0);
        (, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(amountPerSec, 1e20);
        assertEq(lastPaid, 10000);
        assertEq(token, address(llamaToken));
        assertEq(starts, 10000);
        assertEq(ends, 10000000);
        assertEq(totalPaidPerSec, 1e20);
        assertEq(llamaPayV2Payer.nextTokenId(), 1);
    }

    function createStreamAlreadyEnded() external {
        vm.warp(50000);
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1e20,
            10000,
            20000
        );
        (, uint48 lastPaid, , , ) = llamaPayV2Payer.streams(0);
        (, uint256 totalPaidPerSec, , ) = llamaPayV2Payer.tokens(
            address(llamaToken)
        );
        assertEq(lastPaid, 0);
        assertEq(totalPaidPerSec, 0);
        assertEq(llamaPayV2Payer.debts(0), 10000 * 1e20);
    }

    function createStreamStartBeforeCall() external {
        vm.prank(alice);
        llamaPayV2Payer.createStream(
            address(llamaToken),
            bob,
            1e20,
            5000,
            20000
        );
        assertEq(llamaPayV2Payer.debts(0), 5000 *1e20);
    }
}
