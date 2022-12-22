// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import {ScheduledTransfers} from "./ScheduledTransfers.sol";

interface LlamaPayV2Factory {
    function calculateLlamaPayAddress(address)
        external
        view
        returns (address, bool);
}

error LLAMAPAY_DOESNT_EXIST();

contract ScheduledTransfersFactory {
    bytes32 constant INIT_CODEHASH =
        keccak256(type(ScheduledTransfers).creationCode);

    address public factory;

    address public owner;
    address public oracle;

    constructor(address _factory) {
        factory = _factory;
    }

    function createContract(address _oracle) external returns (address createdContract) {
        (address predicted, bool deployed) = LlamaPayV2Factory(factory)
            .calculateLlamaPayAddress(msg.sender);
        if (!deployed) revert LLAMAPAY_DOESNT_EXIST();
        owner = msg.sender;
        oracle = _oracle;
        createdContract = address(
            new ScheduledTransfers{
                salt: bytes32(uint256(uint160(msg.sender)))
            }()
        );
    }

    function predictContract(address _owner)
        public
        view
        returns (address predicted, bool deployed)
    {
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            bytes32(uint256(uint160(_owner))),
                            INIT_CODEHASH
                        )
                    )
                )
            )
        );
        deployed = predicted.code.length != 0;
    }
}
