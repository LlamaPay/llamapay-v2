//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.16;

import "forge-std/Script.sol";
import "../src/LlamaPayV2Factory.sol";

contract DeployFactoryScript is Script {
    function run() external {
        vm.startBroadcast();
        LlamaPayV2Factory factory = new LlamaPayV2Factory{salt: bytes32("llamao")}();
        vm.stopBroadcast();
    }
}