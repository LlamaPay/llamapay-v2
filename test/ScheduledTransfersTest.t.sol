// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {ScheduledTransfersFactory} from "../src/ScheduledTransfersFactory.sol";
import {ScheduledTransfers} from "../src/ScheduledTransfers.sol";
import "./LlamaToken.sol";

contract ScheduledTransfersTest is Test {
    ScheduledTransfersFactory public factory;
    ScheduledTransfers public payer;
    LlamaToken public llamaToken;

    address public immutable alice = address(1);
    address public immutable oracle = address(2);
    uint256[] public ids;

    function setUp() external {
        factory = new ScheduledTransfersFactory();
        llamaToken = new LlamaToken();
        llamaToken.mint(alice, 10000 * 1e18);
        vm.startPrank(alice);
        payer = ScheduledTransfers(
            factory.createContract(oracle, address(llamaToken), 1000 * 1e8)
        );
        llamaToken.transfer(address(payer), 10000 * 1e18);
        vm.stopPrank();
    }

    function testStuff() external {
        vm.startPrank(alice);
        payer.scheduleTransfer(alice, 1000 * 1e8, 0, 100000, 86400);
        vm.warp(86400);
        ids.push(0);
        vm.stopPrank();
        vm.prank(oracle);
        payer.withdraw(ids, address(llamaToken), 1000 * 1e8, 86400);
        assertEq(llamaToken.balanceOf(alice), 1000);
    }
}
