//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.16;

import "forge-std/Script.sol";
import "../src/ScheduledTransfersFactory.sol";

contract DeployScheduledTransfersScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_2");
        vm.startBroadcast(deployerPrivateKey);
        ScheduledTransfersFactory factory = new ScheduledTransfersFactory{
            salt: bytes32("llamao")
        }();
        factory.createContract(
            0xf45363F5114c8B5F834F99cE0A07bD345ec5eeb6,
            0x4200000000000000000000000000000000000042,
            100e8
        );
        factory.createContract(
            0xf45363F5114c8B5F834F99cE0A07bD345ec5eeb6,
            0x4200000000000000000000000000000000000042,
            100e8
        );
        vm.stopBroadcast();
    }
}
