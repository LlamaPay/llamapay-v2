// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {LlamaPayV2Payer} from "./LlamaPayV2Payer.sol";
import "./BoringBatchable.sol";

interface ScheduledTransfersFactory {
    function param() external view returns (address);
}

error NOT_OWNER();
error NOT_ORACLE();
error NOT_OWNER_OR_WHITELISTED();
error INVALID_TIMESTAMP();

contract ScheduledTransfers is ERC721, BoringBatchable {
    using SafeTransferLib for ERC20;

    struct Payment {
        address token;
        uint32 lastPaid;
        uint32 ends;
        uint32 frequency;
        uint256 usdAmount;
    }

    address public oracle;
    address public owner;
    address public llamaPayV2;
    uint256 public nextTokenId;

    mapping(uint256 => Payment) public payments;
    mapping(uint256 => address) public redirects;

    constructor(address _oracle)
        ERC721("LlamaPay V2 Scheduled Transfer", "LLAMAPAY")
    {
        llamaPayV2 = ScheduledTransfersFactory(msg.sender).param();
        owner = LlamaPayV2Payer(llamaPayV2).owner();
        oracle = _oracle;
    }

    modifier onlyOwnerAndWhitelisted() {
        if (
            msg.sender != owner &&
            LlamaPayV2Payer(llamaPayV2).payerWhitelists(msg.sender) != 1
        ) revert NOT_OWNER_OR_WHITELISTED();
        _;
    }

    function tokenURI(uint256 id)
        public
        view
        virtual
        override
        returns (string memory)
    {
        return "";
    }

    function scheduleTransfer(
        address _token,
        address _to,
        uint256 _usdAmount,
        uint32 _starts,
        uint32 _ends,
        uint32 _frequency
    ) external onlyOwnerAndWhitelisted {
        uint256 id = nextTokenId;
        _safeMint(_to, id);
        payments[id] = Payment({
            token: _token,
            lastPaid: _starts,
            ends: _ends,
            frequency: _frequency,
            usdAmount: _usdAmount
        });
        unchecked {
            nextTokenId++;
        }
    }

    function cancelTransfer(uint256 _id) external onlyOwnerAndWhitelisted {
        payments[_id].ends = uint32(block.timestamp);
    }

    function withdraw(
        uint256 _id,
        uint256 _price,
        uint256 _timestamp,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        address nftOwner = ownerOf(_id);
        if (
            msg.sender != nftOwner &&
            msg.sender != owner
        ) revert NOT_OWNER_OR_WHITELISTED();
        Payment storage payment = payments[_id];
        address resolved = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n96",
                    _price,
                    _timestamp,
                    block.chainid
                )
            ),
            v,
            r,
            s
        );
        if (_timestamp > payment.ends) revert INVALID_TIMESTAMP();
        if (resolved != oracle) revert NOT_ORACLE();
        uint256 updatedTimestamp = payment.lastPaid + payment.frequency;
        uint256 owed;
        unchecked {
            if (updatedTimestamp >= payment.ends) {
                if (_timestamp != payment.ends) revert INVALID_TIMESTAMP();
                owed = ((payment.ends - payment.lastPaid) * payment.usdAmount * _price) / payment.frequency;
                payments[_id].lastPaid = payment.ends;
            } else {
                if (_timestamp != updatedTimestamp) revert INVALID_TIMESTAMP();
                owed = payment.usdAmount * _price;
                payments[_id].lastPaid = uint32(updatedTimestamp);
            }
        }
        address to;
        address redirect = redirects[_id];
        if (redirect != address(0)) {
            to = redirect;
        } else {
            to = nftOwner;
        }
        ERC20(payment.token).safeTransfer(to, owed / 1e18);
    }

    function setRedirect(uint256 _id, address _redirectTo) external {
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        redirects[_id] = _redirectTo;
    }

    function changeOracle(address newOracle) external {
        if (msg.sender != owner) revert NOT_OWNER();
        oracle = newOracle;
    }
}
