// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import "./LlamaPayV2Payer.sol";
import "./BoringBatchable.sol";

error AlreadyDeployed();

contract LlamaPayV2Factory is BoringBatchable {
    bytes32 constant INIT_CODEHASH =
        keccak256(type(LlamaPayV2Payer).creationCode);

    uint256 public amtOfPayers;
    address public param;

    mapping(uint256 => address) public payerContracts;

    event LlamaPayContractCreated(address owner, address ownerContract);

    /// @notice Creates LlamaPay V2 Payer contract
    function createLlamaPayContract() external returns (address llamapay) {
        param = msg.sender;
        llamapay = address(
            new LlamaPayV2Payer{salt: bytes32(uint256(uint160(msg.sender)))}()
        );
        payerContracts[amtOfPayers] = llamapay;
        unchecked {
            amtOfPayers++;
        }
        emit LlamaPayContractCreated(msg.sender, llamapay);
    }

    /// @notice Calculates CREATE2 address for payer
    /// @param _owner owner
    function calculateLlamaPayAddress(address _owner)
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
