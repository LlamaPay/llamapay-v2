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
    mapping(address => mapping(address => uint256)) public withdrawalWhitelists;
    mapping(address => address) public redirects;

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

    /// @notice set redirect for sender
    /// @param _redirectTo address to redirect to
    function setRedirect(address _redirectTo) external {
        redirects[msg.sender] = _redirectTo;
    }

    /// @notice reset redirect for sender
    function resetRedirect() external {
        redirects[msg.sender] = address(0);
    }

    /// @notice approve whitelisting for withdrawals
    /// @param _toApprove address to approve
    function approveWithdrawalWhitelist(address _toApprove) external {
        withdrawalWhitelists[msg.sender][_toApprove] = 1;
    }

    /// @notice revoke whitelisting for withdrawals
    function revokeWithdrawalWhitelist(address _toRevoke) external {
        withdrawalWhitelists[msg.sender][_toRevoke] = 0;
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
