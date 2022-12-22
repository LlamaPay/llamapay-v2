// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/LlamaPayV2Factory.sol";
import "../src/LlamaPayV2Payer.sol";

contract LlamaPayV2FactoryTest is Test {
    LlamaPayV2Factory public llamaPayV2Factory;

    address public immutable alice = address(1);
    address public immutable bob = address(2);
    address public immutable steve = address(3);
    

    function setUp() public {
        llamaPayV2Factory = new LlamaPayV2Factory();
    }

    function testCreatePayer() external {
        vm.prank(alice);
        address payerContract = address(
            llamaPayV2Factory.createLlamaPayContract()
        );
        (address predictedAddress, bool deployed) = llamaPayV2Factory
            .calculateLlamaPayAddress(alice);
        assertEq(payerContract, predictedAddress);
        assertEq(deployed, true);
    }

    function testCreateMultiplePayer() external {
        vm.prank(alice);
        address payerContract = address(
            llamaPayV2Factory.createLlamaPayContract()
        );
        (address predictedAddress, bool deployed) = llamaPayV2Factory
            .calculateLlamaPayAddress(alice);
        assertEq(payerContract, predictedAddress);
        assertEq(deployed, true);

        vm.prank(bob);
        payerContract = address(llamaPayV2Factory.createLlamaPayContract());
        (predictedAddress, deployed) = llamaPayV2Factory
            .calculateLlamaPayAddress(bob);
        assertEq(payerContract, predictedAddress);
        assertEq(deployed, true);

        vm.prank(steve);
        payerContract = address(llamaPayV2Factory.createLlamaPayContract());
        (predictedAddress, deployed) = llamaPayV2Factory
            .calculateLlamaPayAddress(steve);
        assertEq(payerContract, predictedAddress);
        assertEq(deployed, true);
    }

    function testCreateMultiplePayer2() external {
        for (uint256 index = 10; index < 110; index++) {
            address aaaa = address(uint160(index));
            vm.prank(aaaa);
            llamaPayV2Factory.createLlamaPayContract();
        }
    }

    function testRevertsIfCreatedTwice() external {
        vm.startPrank(alice);
        llamaPayV2Factory.createLlamaPayContract();
        vm.expectRevert();
        llamaPayV2Factory.createLlamaPayContract();
        vm.stopPrank();
    }
}
