// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";
import "./forks/BoringBatchable.sol";

interface ScheduledTransfersFactory {
    function owner() external view returns (address);
    function oracle() external view returns (address);
}

error NOT_OWNER();
error NOT_ORACLE();
error NOT_OWNER_OR_WHITELISTED();
error INVALID_TIMESTAMP();
error FUTURE_TIMESTAMP();
error MAX_PRICE();
error STREAM_DOES_NOT_EXIST();
error INVALID_TOKEN();

contract ScheduledTransfers is ERC721, BoringBatchable {
    using SafeTransferLib for ERC20;

    struct Payment {
        address token;
        uint32 lastPaid;
        uint32 ends;
        uint32 frequency;
        uint256 usdAmount;
    }

    string public constant baseURI = "https://nft.llamapay.io/scheduled/";
    address public oracle;
    address public immutable owner;
    uint256 public nextTokenId;

    mapping(uint256 => Payment) public payments;
    mapping(uint256 => address) public redirects;
    mapping(address => uint256) public maxPrice;

    constructor()
        ERC721("LlamaPay V2 Scheduled Transfer", "LLAMAPAY")
    {
        oracle = ScheduledTransfersFactory(msg.sender).oracle();
        owner = ScheduledTransfersFactory(msg.sender).owner();
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NOT_OWNER();
        _;
    }

    function tokenURI(uint256 _id)
        public
        view
        virtual
        override
        returns (string memory)
    {
        if (ownerOf(_id) == address(0)) revert STREAM_DOES_NOT_EXIST();
        return
            string(
                abi.encodePacked(
                    baseURI,
                    Strings.toString(block.chainid),
                    "/",
                    Strings.toHexString(uint160(address(this)), 20),
                    "/",
                    Strings.toString(_id)
                )
            );
    }

    function scheduleTransfer(
        address _token,
        address _to,
        uint256 _usdAmount,
        uint32 _starts,
        uint32 _ends,
        uint32 _frequency
    ) external onlyOwner {
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

    function cancelTransfer(uint256 _id) external onlyOwner {
        payments[_id].ends = uint32(block.timestamp);
    }

    function withdrawPayer(address token, uint256 amount) external onlyOwner {
        ERC20(token).safeTransfer(owner, amount);
    }

    function withdraw(
        uint256[] calldata ids,
        address _token,
        uint256 _price,
        uint256 _timestamp
    ) external {
        if(_timestamp > block.timestamp) revert FUTURE_TIMESTAMP();
        if (msg.sender != oracle) revert NOT_ORACLE();
        if (_price > maxPrice[_token]) revert MAX_PRICE();
        uint256 i = 0;
        uint length = ids.length;
        while (i < length) {
            _withdraw(ids[i], _token, _price, _timestamp);
            unchecked {
                i++;
            }
        }
    }

    function _withdraw(
        uint256 _id,
        address _token,
        uint256 _price,
        uint256 _timestamp
    ) private {
        Payment storage payment = payments[_id];
        if (payment.token != _token) revert INVALID_TOKEN();
        if (_timestamp > payment.ends) revert INVALID_TIMESTAMP();
        uint256 updatedTimestamp = payment.lastPaid + payment.frequency;
        if (_timestamp > updatedTimestamp) revert INVALID_TIMESTAMP();
        uint256 owed;
        unchecked {
            owed =
                ((_timestamp - payment.lastPaid) * payment.usdAmount * _price) /
                payment.frequency;
            payments[_id].lastPaid = uint32(updatedTimestamp);
        }
        address to;
        address redirect = redirects[_id];
        address nftOwner = ownerOf(_id);
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

    function changeOracle(address newOracle) external onlyOwner {
        oracle = newOracle;
    }

    function setMaxPrice(address token, uint256 newMaxPrice)
        external
        onlyOwner
    {
        maxPrice[token] = newMaxPrice;
    }
}
