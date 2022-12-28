// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import {ScheduledTransfers} from "./ScheduledTransfers.sol";
import "./forks/BoringBatchable.sol";

contract ScheduledTransfersFactory is BoringBatchable {
    address public owner;
    address public oracle;
    address public token;

    event PoolCreated(
        address pool,
        address owner,
        address token,
        address oracle
    );

    function createContract(address _oracle, address _token)
        external
        returns (address createdContract)
    {
        owner = msg.sender;
        oracle = _oracle;
        token = _token;
        createdContract = address(new ScheduledTransfers());
        emit PoolCreated(createdContract, msg.sender, _token, _oracle);
    }
}
