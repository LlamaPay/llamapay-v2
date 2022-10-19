//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.16;

import "forge-std/Script.sol";
import "../src/LlamaPayV2Factory.sol";

contract DeployFactoryScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 otherPrivateKey = vm.envUint("PRIVATE_KEY_2");
        vm.startBroadcast(deployerPrivateKey);
        LlamaPayV2Factory factory = new LlamaPayV2Factory{
            salt: bytes32("llamao")
        }();
        factory.createLlamaPayContract();
        vm.stopBroadcast();
        vm.startBroadcast(otherPrivateKey);
        factory.createLlamaPayContract();
        vm.stopBroadcast();
    }
}
