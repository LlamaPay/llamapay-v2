// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import  {ScheduledTransfersFactory} from "../src/ScheduledTransfersFactory.sol";
import  {LlamaPayV2Factory} from "../src/LlamaPayV2Factory.sol";

contract ScheduledTransfersFactoryTest is Test {
    LlamaPayV2Factory public llamaPayV2Factory;
    ScheduledTransfersFactory public scheduledTransfersFactory;

    address public immutable alice = address(1);
    address public immutable bob = address(2);

    function setUp() public {
        llamaPayV2Factory = new LlamaPayV2Factory();
        scheduledTransfersFactory = new ScheduledTransfersFactory(address(llamaPayV2Factory));  
        vm.prank(alice);
        llamaPayV2Factory.createLlamaPayContract(); 
    }

    function testCreate() public {
        vm.prank(alice);
        address created = address(scheduledTransfersFactory.createContract(bob));
        (address predictedAddress, bool deployed) = scheduledTransfersFactory.predictContract(alice);
        assertEq(created, predictedAddress);
        assertEq(deployed, true);
    }

}
