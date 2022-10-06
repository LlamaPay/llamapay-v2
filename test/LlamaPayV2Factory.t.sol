// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/LlamaPayV2Factory.sol";
import "../src/LlamaPayV2Payer.sol";

contract LlamaPayV2FactoryTest is Test {
    LlamaPayV2Factory public llamaPayV2Factory;

    address public immutable alice = address(1);

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
}
