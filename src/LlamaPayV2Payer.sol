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
error INVALID_START();
error NONZERO_REDEEMABLE();

/// @title LlamaPayV2 Payer Contract
/// @author nemusona
contract LlamaPayV2Payer is ERC721, BoringBatchable {
    using SafeTransferLib for ERC20;

    struct Token {
        uint256 balance;
        uint256 totalPaidPerSec;
        uint216 divisor;
        uint40 lastUpdate;
    }

    struct Stream {
        uint208 amountPerSec;
        uint48 paidUpTo;
        address token;
        uint48 starts;
        uint48 ends;
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
        uint48 starts,
        uint48 ends
    );
    event StopStream(uint256 id);

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
            tokens[_token].divisor = uint216(10**(20 - token.decimals()));
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

    /// @notice create stream
    /// @param _token token
    /// @param _to payee
    /// @param _amountPerSec stream per sec (20 decimals);
    /// @param _starts stream to start
    function createStream(
        address _token,
        address _to,
        uint208 _amountPerSec,
        uint48 _starts,
        uint48 _ends
    ) external {
        uint256 id = _createStream(_token, _to, _amountPerSec, _starts, _ends);
        emit CreateStream(id, _token, _to, _amountPerSec, _starts, _ends);
    }

    /// @notice stop stream
    /// @param _id token id
    function stopStream(uint256 _id) external {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();

        _updateToken(streams[_id].token);
        _terminateStream(_id);
    }

    /// @notice burn stream
    /// @param _id token id
    function burnStream(uint256 _id) external {
        if (
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            msg.sender != ownerOf(_id)
        ) revert NOT_OWNER_OR_WHITELISTED();
        if (streams[_id].redeemable > 0) revert NONZERO_REDEEMABLE();

        _burn(_id);
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
        Token storage tokenInfo = tokens[token];

        uint256 available;
        if (stream.paidUpTo == 0) {
            available = stream.redeemable;
        } else if (
            stream.starts > stream.paidUpTo &&
            tokenInfo.lastUpdate >= stream.ends
        ) {
            /// Handles if stream was never initialized but has ended
            uint256 owed = (stream.ends - streams.starts) * stream.amountPerSec;
            streams[_id].redeemable = owed;
            available = owed;
            unchecked {
                streams[_id].paidUpTo = 0;
            }
        } else if (stream.starts > stream.paidUpTo) {
            _initializeStream(_id);
            available = streams[_id].redeemable;
        } else if (tokenInfo.lastUpdate >= stream.ends) {
            _terminateStream(_id);
            available = streams[_id].redeemable;
        } else {
            available =
                ((tokenInfo.lastUpdate - stream.paidUpTo) *
                    stream.amountPerSec) +
                stream.redeemable;
        }

        if (_amount > available / tokenInfo.divisor)
            revert AMOUNT_NOT_AVAILABLE();

        address redirect = Factory(factory).redirects(tokenOwner);
        if (redirect != address(0)) {
            to = redirect;
        } else {
            to = tokenOwner;
        }
    }

    function _updateToken(address _token) private {
        Token storage token = tokens[_token];
        uint256 delta = block.timestamp - token.lastUpdate;
        uint256 streamed = delta * token.totalPaidPerSec;

        unchecked {
            if (token.balance >= streamed) {
                tokens[_token].balance -= streamed;
                tokens[_token].lastUpdate = uint40(block.timestamp);
            } else {
                tokens[_token].balance = token.balance % token.totalPaidPerSec;
                tokens[_token].lastUpdate += uint40(
                    token.balance / token.totalPaidPerSec
                );
            }
        }
    }

    function _createStream(
        address _token,
        address _to,
        uint208 _amountPerSec,
        uint48 _starts,
        uint48 _ends
    ) private returns (uint256 id) {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        if (_to == address(0)) revert ZERO_ADDRESS();
        if (_starts >= _ends) revert INVALID_START();

        _updateToken(_token);
        if (block.timestamp > tokens[_token].lastUpdate) revert PAYER_IN_DEBT();

        if (block.timestamp >= _starts) {
            tokens[_token].totalPaidPerSec += _amountPerSec;
        }

        id = tokenId;
        _safeMint(_to, id);

        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            token: _token,
            paidUpTo: uint48(block.timestamp),
            starts: _starts,
            ends: _ends,
            redeemable: 0
        });

        unchecked {
            tokenId++;
        }
    }

    /// Assumes that _updateToken() is called before this
    function _initializeStream(uint256 _id) private {
        Stream storage stream = streams[_id];
        Token storage token = tokens[stream.token];

        /// Will revert if starts > lastUpdate
        uint256 owed = (token.lastUpdate - stream.starts) * stream.amountPerSec;
        /// Essentially pays back debt accrued due to totalPaidPerSec not being updated
        if (token.balance >= owed) {
            tokens[stream.token].balance -= owed;
            streams[_id].redeemable = owed;
            streams[_id].paidUpTo = uint48(token.lastUpdate);
        } else {
            tokens[stream.token].balance = token.balance % stream.amountPerSec;
            uint256 timePaid = token.balance / stream.amountPerSec;
            streams[_id].redeemable = timePaid * stream.amountPerSec;
            streams[_id].paidUpTo = uint48(stream.starts + timePaid);
        }

        tokens[stream.token].totalPaidPerSec += stream.amountPerSec;
    }

    /// Assumes updateToken() is called
    function _terminateStream(uint256 _id) private {
        Stream storage stream = streams[_id];
        Token storage token = tokens[stream.token];

        if (token.lastUpdate > stream.ends) {
            /// Refund overpaid amount to payer balance
            tokens[stream.token].balance +=
                (token.lastUpdate - stream.ends) *
                stream.amountPerSec;
            streams[_id].redeemable +=
                (stream.ends - stream.paidUpTo) *
                stream.amountPerSec;
        } else {
            streams[_id].redeemable +=
                (token.lastUpdate - stream.paidUpTo) *
                stream.amountPerSec;
        }

        unchecked {
            streams[_id].paidUpTo = 0;
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }
    }
}
