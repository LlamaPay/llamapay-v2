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
error INACTIVE_STREAM();
error ACTIVE_STREAM();
error INVALID_STREAM();

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
        uint208 amountPerSec;
        uint48 lastPaid;
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
        uint256 amountPerSec,
        uint48 starts,
        uint48 ends
    );
    event CreateStreamWithReason(
        uint256 id,
        address token,
        address to,
        uint256 amountPerSec,
        uint48 starts,
        uint48 ends,
        string reason
    );
    event CreateStreamWithheld(
        uint256 id,
        address token,
        address to,
        uint256 amountPerSec,
        uint48 starts,
        uint48 ends,
        uint256 withheldPerSec
    );
    event CreateStreamWithheldWithReason(
        uint256 id,
        address token,
        address to,
        uint256 amountPerSec,
        uint48 starts,
        uint48 ends,
        uint256 withheldPerSec,
        string reason
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

    /// @notice creates stream
    /// @param _token token
    /// @param _to recipient
    /// @param _amountPerSec amount per sec (20 decimals)
    /// @param _starts stream to start
    /// @param _ends stream to end
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

    /// @notice creates stream with a reason string
    /// @param _token token
    /// @param _to recipient
    /// @param _amountPerSec amount per sec (20 decimals)
    /// @param _starts stream to start
    /// @param _ends stream to end
    /// @param _reason reason
    function createStreamWithReason(
        address _token,
        address _to,
        uint208 _amountPerSec,
        uint48 _starts,
        uint48 _ends,
        string memory _reason
    ) external {
        uint256 id = _createStream(_token, _to, _amountPerSec, _starts, _ends);
        emit CreateStreamWithReason(
            id,
            _token,
            _to,
            _amountPerSec,
            _starts,
            _ends,
            _reason
        );
    }

    /// @notice creates stream with amount withheld
    /// @param _token token
    /// @param _to recipient
    /// @param _amountPerSec amount per sec (20 decimals)
    /// @param _starts stream to start
    /// @param _ends stream to end
    /// @param _withheldPerSec withheld per sec (20 decimals)
    function createStreamWithheld(
        address _token,
        address _to,
        uint208 _amountPerSec,
        uint48 _starts,
        uint48 _ends,
        uint256 _withheldPerSec
    ) external {
        uint256 id = _createStream(_token, _to, _amountPerSec, _starts, _ends);
        emit CreateStreamWithheld(
            id,
            _token,
            _to,
            _amountPerSec,
            _starts,
            _ends,
            _withheldPerSec
        );
    }

    /// @notice creates stream with a reason string and withheld
    /// @param _token token
    /// @param _to recipient
    /// @param _amountPerSec amount per sec (20 decimals)
    /// @param _starts stream to start
    /// @param _ends stream to end
    /// @param _withheldPerSec withheld per sec (20 decimals)
    /// @param _reason reason
    function createStreamWithheldWithReason(
        address _token,
        address _to,
        uint208 _amountPerSec,
        uint48 _starts,
        uint48 _ends,
        uint256 _withheldPerSec,
        string memory _reason
    ) external {
        uint256 id = _createStream(_token, _to, _amountPerSec, _starts, _ends);
        emit CreateStreamWithheldWithReason(
            id,
            _token,
            _to,
            _amountPerSec,
            _starts,
            _ends,
            _withheldPerSec,
            _reason
        );
    }

    /// @notice modifies current stream
    /// @param _id token id
    /// @param _newAmountPerSec modified amount per sec (20 decimals)
    function modifyStream(uint256 _id, uint208 _newAmountPerSec) external {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        Stream storage stream = streams[_id];
        if (stream.lastPaid == 0) revert INACTIVE_STREAM();
        if (_id >= tokenId) revert INVALID_STREAM();

        _updateToken(stream.token);
        Token storage token = tokens[stream.token];

        tokens[stream.token].totalPaidPerSec += _newAmountPerSec;
        unchecked {
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }

        streams[_id].redeemable +=
            (token.lastUpdate - stream.lastPaid) *
            stream.amountPerSec;
        streams[_id].amountPerSec = _newAmountPerSec;
        streams[_id].lastPaid = token.lastUpdate;
    }

    /// @notice pauses current stream
    /// @param _id token id
    function stopStream(uint256 _id) external {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        Stream storage stream = streams[_id];
        if (stream.lastPaid == 0) revert INACTIVE_STREAM();
        if (_id >= tokenId) revert INVALID_STREAM();

        _updateToken(stream.token);

        streams[_id].redeemable +=
            (tokens[stream.token].lastUpdate - stream.lastPaid) *
            stream.amountPerSec;

        unchecked {
            streams[_id].lastPaid = 0;
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }
    }

    /// @notice resumes a stopped stream
    /// @param _id token id
    function resumeStream(uint256 _id) external {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        Stream storage stream = streams[_id];
        if (stream.lastPaid > 0) revert ACTIVE_STREAM();
        if (block.timestamp >= stream.ends) revert INVALID_START();
        if (_id >= tokenId) revert INVALID_STREAM();

        _updateToken(stream.token);
        if (block.timestamp > tokens[stream.token].lastUpdate)
            revert PAYER_IN_DEBT();

        streams[_id].lastPaid = uint48(block.timestamp);
        tokens[stream.token].totalPaidPerSec += stream.amountPerSec;
    }

    /// @notice burns an inactive and withdrawn stream
    /// @param _id token id
    function burnStream(uint256 _id) external {
        if (
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            msg.sender != ownerOf(_id)
        ) revert NOT_OWNER_OR_WHITELISTED();
        Stream storage stream = streams[_id];
        if (stream.redeemable > 0 || stream.lastPaid != 0)
            revert NOT_CANCELLED_OR_REDEEMABLE();
        if (_id >= tokenId) revert INVALID_STREAM();

        _burn(_id);
    }

    /// @notice add address to whitelist
    /// @param _toWhitelist address to whitelist
    function approvePayerWhitelist(address _toWhitelist) external {
        if (msg.sender != owner) revert NOT_OWNER();
        payerWhitelists[_toWhitelist] = 1;
    }

    /// @notice remove address from whitelist
    /// @param _toRemove address to remove
    function revokePayerWhitelist(address _toRemove) external {
        if (msg.sender != owner) revert NOT_OWNER();
        payerWhitelists[_toRemove] = 0;
    }

    /// @notice amount withdrawable from stream
    /// @param _id token id
    /// @return withdrawableAmount wihtdrawable amount (20 decimals)
    /// @return debt debt owed by payer
    /// @return lastUpdate last payer update
    function withdrawable(uint256 _id)
        public
        view
        returns (
            uint256 withdrawableAmount,
            uint256 debt,
            uint256 lastUpdate
        )
    {
        Stream storage stream = streams[_id];
        Token storage token = tokens[stream.token];

        uint256 totalStreamed = (block.timestamp - token.lastUpdate) *
            token.totalPaidPerSec;

        if (token.balance >= totalStreamed) {
            lastUpdate = block.timestamp;
        } else {
            lastUpdate =
                token.lastUpdate +
                (token.balance / token.totalPaidPerSec);
        }

        if (stream.lastPaid == 0) {
            withdrawableAmount = stream.redeemable;
        } else if (
            stream.starts > stream.lastPaid &&
            lastUpdate >= stream.starts &&
            lastUpdate >= stream.ends
        ) {
            withdrawableAmount =
                (stream.ends - stream.starts) *
                stream.amountPerSec;
        } else if (
            stream.starts > stream.lastPaid && lastUpdate >= stream.starts
        ) {
            withdrawableAmount =
                (lastUpdate - stream.starts) *
                stream.amountPerSec;
            debt = (block.timestamp - lastUpdate) * stream.amountPerSec;
        } else if (lastUpdate >= stream.ends) {
            withdrawableAmount =
                stream.redeemable +
                ((stream.ends - stream.lastPaid) * stream.amountPerSec);
        } else {
            withdrawableAmount =
                stream.redeemable +
                (lastUpdate - stream.lastPaid) *
                stream.amountPerSec;
            debt = (block.timestamp - lastUpdate) * stream.amountPerSec;
        }

        withdrawableAmount = withdrawableAmount / token.divisor;
    }

    /// @notice updates token balances
    /// @param _token token to update
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

    /// @notice withdraw
    /// @param _id token id
    /// @param _amount amount to withdraw (native decimals)
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
        if (_id >= tokenId) revert INVALID_STREAM();

        token = streams[_id].token;
        _updateStream(_id);

        /// Reverts if payee is going to rug
        streams[_id].redeemable -= _amount * tokens[token].divisor;

        address redirect = Factory(factory).redirects(tokenOwner);
        if (redirect != address(0)) {
            to = redirect;
        } else {
            to = tokenOwner;
        }
    }

    function _updateStream(uint256 _id) private {
        Stream storage stream = streams[_id];
        _updateToken(stream.token);
        uint48 lastUpdate = tokens[stream.token].lastUpdate;

        /// Literally do nothing if stream is inactive
        if (stream.lastPaid == 0) {
            /// NOTHING
        } else if (
            stream.starts > stream.lastPaid &&
            lastUpdate >= stream.starts &&
            lastUpdate >= stream.ends
        ) {
            /// If stream never initialized and if stream ended before stream initalized
            /// Repays payer spent on stream before stream start and after stream end
            tokens[stream.token].balance +=
                ((stream.starts - stream.lastPaid) +
                    (lastUpdate - stream.ends)) *
                stream.amountPerSec;
            streams[_id].redeemable =
                (stream.ends - stream.starts) *
                stream.amountPerSec;
            unchecked {
                streams[_id].lastPaid = 0;
                tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
            }
        } else if (
            stream.starts > stream.lastPaid && lastUpdate >= stream.starts
        ) {
            /// If stream never initialized but hasn't ended
            /// Initializes stream and repays payer for spent on stream before start
            tokens[stream.token].balance +=
                (stream.starts - stream.lastPaid) *
                stream.amountPerSec;
            streams[_id].redeemable =
                (lastUpdate - stream.starts) *
                stream.amountPerSec;
            unchecked {
                streams[_id].lastPaid = lastUpdate;
            }
        } else if (lastUpdate >= stream.ends) {
            /// If stream is initialized but has ended
            /// stops stream and repays payer for spent after stream end
            tokens[stream.token].balance +=
                (lastUpdate - stream.ends) *
                stream.amountPerSec;
            streams[_id].redeemable +=
                (stream.ends - stream.lastPaid) *
                stream.amountPerSec;
            unchecked {
                streams[_id].lastPaid = 0;
                tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
            }
        } else {
            /// If stream still running then do normal calc
            streams[_id].redeemable +=
                (lastUpdate - stream.lastPaid) *
                stream.amountPerSec;
            unchecked {
                streams[_id].lastPaid = lastUpdate;
            }
        }
    }

    /// @notice create stream
    /// @param _token token
    /// @param _to recipient
    /// @param _amountPerSec amount per sec (20 decimals)
    /// @param _starts stream to start
    /// @param _ends stream to end
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
        if (block.timestamp > _starts || _starts >= _ends)
            revert INVALID_START();

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
            ends: _ends,
            redeemable: 0
        });

        unchecked {
            tokenId++;
        }
    }
}
