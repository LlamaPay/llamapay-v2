//SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "./BoringBatchable.sol";

interface Factory {
    function param() external view returns (address);

    function withdrawalWhitelists(address, address)
        external
        view
        returns (uint256);

    function redirects(address) external view returns (address);
}

error NOT_OWNER_OR_WHITELISTED();
error AMOUNT_NOT_AVAILABLE();
error PAYER_IN_DEBT();
error NOT_OWNER();
error ZERO_ADDRESS();
error NOT_CANCELLED_OR_REDEEMABLE();
error INVALID_START();

/// @title LlamaPayV2 Payer Contract
/// @author nemusona
contract LlamaPayV2Payer is ERC721, BoringBatchable {
    using SafeTransferLib for ERC20;

    struct Token {
        uint256 balance;
        uint256 totalPaidPerSec;
        uint208 divisor;
        uint48 lastUpdate;
    }

    struct Stream {
        uint256 amountPerSec;
        address token;
        uint48 starts;
        uint48 lastPaid;
        uint256 redeemable;
    }

    address public immutable factory;
    address public immutable owner;
    uint256 public tokenId;

    mapping(address => Token) public tokens;
    mapping(uint256 => Stream) public streams;
    mapping(address => uint256) public payerWhitelists;

    event Deposit(address token, address from, uint256 amount);
    event WithdrawPayer(address token, address to, uint256 amount);
    event Withdraw(uint256 id, address token, address to, uint256 amount);
    event CreateStream(
        uint256 id,
        address token,
        address to,
        uint248 amountPerSec,
        uint48 starts
    );

    constructor() ERC721("LlamaPay V2 Stream", "LLAMAPAY-V2-STREAM") {
        factory = msg.sender;
        owner = Factory(msg.sender).param();
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

    /// @notice deposit into vault (anybody can deposit)
    /// @param _token token
    /// @param _amount amount (native token decimal)
    function deposit(address _token, uint256 _amount) external {
        ERC20 token = ERC20(_token);

        // Stores token divisor if it is the first time being deposited
        // Saves on having to call decimals() for conversions
        if (tokens[_token].divisor == 0) {
            tokens[_token].divisor = uint208(10**(20 - token.decimals()));
        }

        tokens[_token].balance += _amount * tokens[_token].divisor;
        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(_token, msg.sender, _amount);
    }

    /// @notice withdraw tokens that have not been streamed yet
    /// @param _token token
    /// @param _amount amount (native token decimals)
    function withdrawPayer(address _token, uint256 _amount) external {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();

        _updateToken(_token);

        uint256 toDeduct;
        unchecked {
            toDeduct = _amount * tokens[_token].divisor;
        }
        /// Will revert if not enough after updating Token struct
        tokens[_token].balance -= toDeduct;

        ERC20(_token).safeTransfer(msg.sender, _amount);

        emit WithdrawPayer(_token, msg.sender, _amount);
    }

    /// @notice withdraw from stream
    /// @param _id token id
    /// @param _amount amount (native decimals)
    function withdraw(uint256 _id, uint256 _amount) external {
        (address token, address to) = _withdraw(_id, _amount);

        ERC20(token).safeTransfer(to, _amount);
        emit Withdraw(_id, token, to, _amount);
    }

    function createStream(
        address _token,
        address _to,
        uint208 _amountPerSec,
        uint48 _starts
    ) external {
        uint256 id = _createStream(_token, _to, _amountPerSec, _starts);
        emit CreateStream(id, _token, _to, _amountPerSec, _starts);
    }

    function stopStream(uint256 _id) external {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();

        Stream storage stream = streams[_id];
        _updateToken(stream.token);

        streams[_id].redeemable +=
            (tokens[stream.token].lastUpdate - stream.lastPaid) *
            stream.amountPerSec;

        unchecked {
            streams[_id].lastPaid = 0;
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }
    }

    function resumeStream(uint256 _id) external {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();

        Stream storage stream = streams[_id];

        _updateToken(stream.token);
        if (block.timestamp > tokens[stream.token].lastUpdate)
            revert PAYER_IN_DEBT();

        streams[_id].lastPaid = uint48(block.timestamp);
        tokens[stream.token].totalPaidPerSec += stream.amountPerSec;
    }

    function burnStream(uint256 _id) external {
        if (
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            msg.sender != ownerOf(_id)
        ) revert NOT_OWNER_OR_WHITELISTED();
        Stream storage stream = streams[_id];
        if (stream.redeemable > 0 || stream.lastPaid != 0)
            revert NOT_CANCELLED_OR_REDEEMABLE();

        _burn(_id);
    }

    function _updateToken(address _token) private {
        Token storage token = tokens[_token];
        uint256 streamed = (block.timestamp - token.lastUpdate) *
            token.totalPaidPerSec;

        unchecked {
            if (token.balance >= streamed) {
                tokens[_token].balance -= streamed;
                tokens[_token].lastUpdate = uint48(block.timestamp);
            } else {
                tokens[_token].balance = token.balance % token.totalPaidPerSec;
                tokens[_token].lastUpdate += uint48(
                    token.balance / token.totalPaidPerSec
                );
            }
        }
    }

    function _withdraw(uint256 _id, uint256 _amount)
        private
        returns (address token, address to)
    {
        address tokenOwner = ownerOf(_id);
        if (
            msg.sender != tokenOwner &&
            Factory(factory).withdrawalWhitelists(tokenOwner, msg.sender) !=
            1 &&
            msg.sender != owner
        ) revert NOT_OWNER_OR_WHITELISTED();

        Stream storage stream = streams[_id];
        token = stream.token;
        _updateToken(token);
        uint48 lastUpdate = tokens[token].lastUpdate;

        if (
            stream.starts > stream.lastPaid &&
            lastUpdate >= stream.starts &&
            stream.lastPaid != 0
        ) {
            tokens[token].balance +=
                (stream.starts - stream.lastPaid) *
                stream.amountPerSec;
            streams[_id].redeemable =
                (lastUpdate - stream.starts) *
                stream.amountPerSec;
            streams[_id].lastPaid = lastUpdate;
        } else if (stream.lastPaid != 0) {
            streams[_id].redeemable +=
                (lastUpdate - stream.lastPaid) *
                stream.amountPerSec;
            streams[_id].lastPaid = lastUpdate;
        }

        streams[_id].redeemable -= _amount * tokens[token].divisor;

        address redirect = Factory(factory).redirects(tokenOwner);
        if (redirect != address(0)) {
            to = redirect;
        } else {
            to = tokenOwner;
        }
    }

    function _createStream(
        address _token,
        address _to,
        uint208 _amountPerSec,
        uint48 _starts
    ) private returns (uint256 id) {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        if (_to == address(0)) revert ZERO_ADDRESS();
        if (block.timestamp > _starts) revert INVALID_START();

        _updateToken(_token);
        if (block.timestamp > tokens[_token].lastUpdate) revert PAYER_IN_DEBT();

        tokens[_token].totalPaidPerSec += _amountPerSec;

        id = tokenId;
        _safeMint(_to, id);

        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            token: _token,
            lastPaid: uint48(block.timestamp),
            starts: _starts,
            redeemable: 0
        });

        unchecked {
            tokenId++;
        }
    }
}
