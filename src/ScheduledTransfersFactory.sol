// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import {ScheduledTransfers} from "./ScheduledTransfers.sol";

error LLAMAPAY_DOESNT_EXIST();

contract ScheduledTransfersFactory {
    bytes32 constant INIT_CODEHASH =
        keccak256(type(ScheduledTransfers).creationCode);

    event PoolCreated(address pool, address owner);

    function createContract(address _oracle) external returns (address createdContract) {
        createdContract = address(
            new ScheduledTransfers{
                salt: bytes32(uint256(uint160(msg.sender)))
            }(_oracle, msg.sender)
        );
        emit PoolCreated(createdContract, msg.sender);
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
