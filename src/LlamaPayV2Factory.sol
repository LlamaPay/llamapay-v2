//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.17;

import "./LlamaPayV2Payer.sol";

error AlreadyDeployed();

contract LlamaPayV2Factory {
    bytes32 constant INIT_CODEHASH =
        keccak256(type(LlamaPayV2Payer).creationCode);

    uint256 public ownerCount;
    address public param;

    mapping(uint256 => address) public ownerContracts;
    mapping(address => mapping(address => uint256)) public whitelists;
    mapping(address => address) public redirects;

    event LlamaPayContractCreated(address owner, address ownerContract);

    /// @notice Creates LlamaPay V2 Payer contract
    function createLlamaPayContract() external returns (address llamapay) {
        param = msg.sender;
        llamapay = address(
            new LlamaPayV2Payer{salt: bytes32(uint256(uint160(msg.sender)))}()
        );
        ownerContracts[ownerCount] = llamapay;
        unchecked {
            ownerCount++;
        }
        emit LlamaPayContractCreated(msg.sender, llamapay);
    }

    function setRedirect(address _redirectTo) external {
        redirects[msg.sender] = _redirectTo;
    }

    function resetRedirect() external {
        redirects[msg.sender] = address(0);
    }

    function approveWhitelist(address _toApprove) external {
        whitelists[msg.sender][_toApprove] = 1;
    }

    function revokeWhitelist(address _toRevoke) external {
        whitelists[msg.sender][_toRevoke] = 0;
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
