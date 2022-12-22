//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.16;

import "forge-std/Script.sol";
import "../src/ScheduledTransfersFactory.sol";

contract DeployScheduledTransfersScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 otherPrivateKey = vm.envUint("PRIVATE_KEY_2");
        vm.startBroadcast(deployerPrivateKey);
        ScheduledTransfersFactory factory = new ScheduledTransfersFactory{
            salt: bytes32("llamao")
        }(0xF1F26856B93a93602E2B589A6B63CDE87480D352);
        factory.createContract(address(0));
        vm.stopBroadcast();
        vm.startBroadcast(otherPrivateKey);
        factory.createContract(address(0));
        vm.stopBroadcast();
    }
}
