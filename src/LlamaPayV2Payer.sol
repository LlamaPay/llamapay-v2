// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "./BoringBatchable.sol";

interface Factory {
    function param() external view returns (address);
}

error NOT_OWNER();
error NOT_OWNER_OR_WHITELISTED();
error INVALID_ADDRESS();
error INVALID_TIME();
error INVALID_STREAM();
error PAYER_IN_DEBT();
error INACTIVE_STREAM();
error ACTIVE_STREAM();
error STREAM_ACTIVE_OR_REDEEMABLE();

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

    address public owner;
    uint256 public nextTokenId;

    mapping(address => Token) public tokens;
    mapping(uint256 => Stream) public streams;
    mapping(address => uint256) public payerWhitelists;
    mapping(uint256 => address) public redirects;
    mapping(uint256 => mapping(address => uint256)) public streamWhitelists;
    mapping(uint256 => uint256) public debts;

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
    event AddPayerWhitelist(address whitelisted);
    event RemovePayerWhitelist(address removed);
    event AddRedirectStream(uint256 id, address redirected);
    event RemoveRedirectStream(uint256 id);
    event AddStreamWhitelist(uint256 id, address whitelisted);
    event RemoveStreamWhitelist(uint256 id, address removed);

    constructor() ERC721("LlamaPay V2 Stream", "LLAMAPAY-V2-STREAM") {
        owner = Factory(msg.sender).param();
    }

    modifier onlyOwnerAndWhitelisted() {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NOT_OWNER();
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

    /// @notice deposit into vault (anybody can deposit)
    /// @param _token token
    /// @param _amount amount (native token decimal)
    function deposit(address _token, uint256 _amount) external {
        ERC20 token = ERC20(_token);
        // Stores token divisor if it is the first time being deposited
        // Saves on having to call decimals() for conversions
        if (tokens[_token].divisor == 0) {
            unchecked {
                tokens[_token].divisor = uint208(10**(20 - token.decimals()));
            }
        }
        tokens[_token].balance += _amount * tokens[_token].divisor;
        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(_token, msg.sender, _amount);
    }

    /// @notice withdraw tokens that have not been streamed yet
    /// @param _token token
    /// @param _amount amount (native token decimals)
    function withdrawPayer(address _token, uint256 _amount)
        external
        onlyOwnerAndWhitelisted
    {
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
        if (_id >= nextTokenId) revert INVALID_STREAM();
        address nftOwner = ownerOf(_id);
        if (
            msg.sender != nftOwner &&
            msg.sender != owner &&
            streamWhitelists[_id][msg.sender] != 1
        ) revert NOT_OWNER_OR_WHITELISTED();
        _updateStream(_id);
        Stream storage stream = streams[_id];

        /// Reverts if payee is going to rug
        streams[_id].redeemable -= _amount * tokens[stream.token].divisor;

        address to;
        address redirect = redirects[_id];
        if (redirect != address(0)) {
            to = redirect;
        } else {
            to = nftOwner;
        }

        ERC20(stream.token).safeTransfer(to, _amount);
        emit Withdraw(_id, stream.token, to, _amount);
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

    /// @notice modifies current stream (RESTARTS STREAM)
    /// @param _id token id
    /// @param _newAmountPerSec modified amount per sec (20 decimals)
    /// @param _newEnd new end time
    function modifyStream(
        uint256 _id,
        uint208 _newAmountPerSec,
        uint48 _newEnd
    ) external onlyOwnerAndWhitelisted {
        if (_id >= nextTokenId) revert INVALID_STREAM();
        _updateStream(_id);
        Stream storage stream = streams[_id];
        /// Prevents people from setting end to time already "paid out"
        if (block.timestamp >= _newEnd) revert INVALID_TIME();

        tokens[stream.token].totalPaidPerSec += _newAmountPerSec;
        unchecked {
            /// Prevents incorrect totalPaidPerSec calculation if stream is inactive
            if (stream.lastPaid > 0) {
                tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
                uint256 lastUpdate = tokens[stream.token].lastUpdate;
                /// Track debt if payer is in debt
                if (block.timestamp > lastUpdate) {
                    /// Add debt owed til modify call
                    debts[_id] +=
                        (block.timestamp - lastUpdate) *
                        stream.amountPerSec;
                }
            }
            streams[_id].amountPerSec = _newAmountPerSec;
            streams[_id].ends = _newEnd;
            streams[_id].lastPaid = uint48(block.timestamp);
        }
    }

    /// @notice Stops current stream
    /// @param _id token id
    function stopStream(uint256 _id, bool _payDebt)
        external
        onlyOwnerAndWhitelisted
    {
        if (_id >= nextTokenId) revert INVALID_STREAM();

        _updateStream(_id);
        Stream storage stream = streams[_id];
        if (stream.lastPaid == 0) revert INACTIVE_STREAM();

        unchecked {
            uint256 lastUpdate = tokens[stream.token].lastUpdate;
            /// If chooses to pay debt and payer is in debt
            if (_payDebt && block.timestamp > lastUpdate) {
                /// Track owed until stopStream call
                debts[_id] +=
                    (block.timestamp - lastUpdate) *
                    stream.amountPerSec;
            }
            streams[_id].lastPaid = 0;
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }
    }

    /// @notice resumes a stopped stream
    /// @param _id token id
    function resumeStream(uint256 _id) external onlyOwnerAndWhitelisted {
        if (_id >= nextTokenId) revert INVALID_STREAM();
        Stream storage stream = streams[_id];
        if (stream.lastPaid > 0) revert ACTIVE_STREAM();
        /// Cannot resume an already ended stream
        if (block.timestamp >= stream.ends) revert INVALID_TIME();

        _updateToken(stream.token);
        if (block.timestamp > tokens[stream.token].lastUpdate)
            revert PAYER_IN_DEBT();

        tokens[stream.token].totalPaidPerSec += stream.amountPerSec;
        unchecked {
            streams[_id].lastPaid = uint48(block.timestamp);
        }
    }

    /// @notice burns an inactive and withdrawn stream
    /// @param _id token id
    function burnStream(uint256 _id) external {
        if (_id >= nextTokenId) revert INVALID_STREAM();
        if (
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            msg.sender != ownerOf(_id)
        ) revert NOT_OWNER_OR_WHITELISTED();
        Stream storage stream = streams[_id];
        /// Prevents somebody from burning an active stream or a stream with balance in it
        if (stream.redeemable > 0 || stream.lastPaid > 0)
            revert STREAM_ACTIVE_OR_REDEEMABLE();

        _burn(_id);
    }

    /// @notice manually update stream
    /// @param _id token id
    function updateStream(uint256 _id) external onlyOwnerAndWhitelisted {
        _updateStream(_id);
    }

    /// @notice repay debt
    /// @param _id token id
    function repayDebt(uint256 _id) external {
        if (_id >= nextTokenId) revert INVALID_STREAM();
        if (
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            msg.sender != ownerOf(_id)
        ) revert NOT_OWNER_OR_WHITELISTED();

        _updateStream(_id);
        unchecked {
            uint256 debt = debts[_id];
            address token = streams[_id].token;
            uint256 balance = tokens[token].balance;
            if (debt > 0) {
                /// If payer balance has enough to pay back debt
                if (balance >= debt) {
                    /// Deduct debt from payer balance and debt is repaid
                    tokens[token].balance -= debt;
                    streams[_id].redeemable += debt;
                    debts[_id] = 0;
                } else {
                    /// Get remaining debt after payer balance is depleted
                    debts[_id] = debt - balance;
                    streams[_id].redeemable += balance;
                    tokens[token].balance = 0;
                }
            }
        }
    }

    /// @notice add address to payer whitelist
    /// @param _toAdd address to whitelist
    function addPayerWhitelist(address _toAdd) external onlyOwner {
        payerWhitelists[_toAdd] = 1;
        emit AddPayerWhitelist(_toAdd);
    }

    /// @notice remove address to payer whitelist
    /// @param _toRemove address to remove from whitelist
    function removePayerWhitelist(address _toRemove) external onlyOwner {
        payerWhitelists[_toRemove] = 0;
        emit RemovePayerWhitelist(_toRemove);
    }

    /// @notice add redirect to stream
    /// @param _id token id
    /// @param _redirectTo address to redirect funds to
    function addRedirectStream(uint256 _id, address _redirectTo) external {
        if (_id >= nextTokenId) revert INVALID_STREAM();
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        redirects[_id] = _redirectTo;
        emit AddRedirectStream(_id, _redirectTo);
    }

    /// @notice remove redirect to stream
    /// @param _id token id
    function removeRedirectStream(uint256 _id) external {
        if (_id >= nextTokenId) revert INVALID_STREAM();
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        redirects[_id] = address(0);
        emit RemoveRedirectStream(_id);
    }

    /// @notice add whitelist to stream
    /// @param _id token id
    /// @param _toAdd address to whitelist
    function addStreamWhitelist(uint256 _id, address _toAdd) external {
        if (_id >= nextTokenId) revert INVALID_STREAM();
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        streamWhitelists[_id][_toAdd] = 1;
        emit AddStreamWhitelist(_id, _toAdd);
    }

    /// @notice remove whitelist to stream
    /// @param _id token id
    /// @param _toRemove address to remove from whitelist
    function removeStreamWhitelist(uint256 _id, address _toRemove) external {
        if (_id >= nextTokenId) revert INVALID_STREAM();
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        streamWhitelists[_id][_toRemove] = 0;
        emit RemoveStreamWhitelist(_id, _toRemove);
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
    ) private onlyOwnerAndWhitelisted returns (uint256 id) {
        if (_to == address(0)) revert INVALID_ADDRESS();
        if (_starts >= _ends) revert INVALID_TIME();
        _updateToken(_token);
        if (block.timestamp > tokens[_token].lastUpdate) revert PAYER_IN_DEBT();

        uint256 owed;
        if (block.timestamp > _starts) {
            /// Calculates amount streamed from start to stream creation
            owed = (block.timestamp - _starts) * _amountPerSec;
            /// Will revert if cannot pay owed balance
            tokens[_token].balance -= owed;
        }

        tokens[_token].totalPaidPerSec += _amountPerSec;
        id = nextTokenId;
        _safeMint(_to, id);
        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            token: _token,
            lastPaid: uint48(block.timestamp),
            starts: _starts,
            ends: _ends,
            redeemable: owed
        });
        unchecked {
            nextTokenId++;
        }
    }

    /// @notice updates token balances
    /// @param _token token to update
    function _updateToken(address _token) private {
        Token storage token = tokens[_token];
        /// Streamed from last update to called
        uint256 streamed = (block.timestamp - token.lastUpdate) *
            token.totalPaidPerSec;
        unchecked {
            if (token.balance >= streamed) {
                /// If enough to pay owed then deduct from balance and update to current timestamp
                tokens[_token].balance -= streamed;
                tokens[_token].lastUpdate = uint48(block.timestamp);
            } else {
                /// If not enough then get remainder paying as much as possible then calculating and adding time paid
                tokens[_token].lastUpdate += uint48(
                    token.balance / token.totalPaidPerSec
                );
                tokens[_token].balance = token.balance % token.totalPaidPerSec;
            }
        }
    }

    /// @notice update stream
    /// @param _id token id
    function _updateStream(uint256 _id) private {
        /// Update Token info to get last update
        Stream storage stream = streams[_id];
        _updateToken(stream.token);
        uint48 lastUpdate = tokens[stream.token].lastUpdate;

        /// If stream is inactive/cancelled
        if (stream.lastPaid == 0) {
            /// Can only withdraw redeeemable so do nothing
        }
        /// Stream not updated after start and has ended
        else if (
            /// Stream not updated after start
            stream.starts > stream.lastPaid &&
            /// Stream ended
            lastUpdate >= stream.ends
        ) {
            /// Refund payer for:
            /// Stream last updated to stream start
            /// Stream ended to token last updated
            tokens[stream.token].balance +=
                ((stream.starts - stream.lastPaid) +
                    (lastUpdate - stream.ends)) *
                stream.amountPerSec;
            /// Payee can redeem:
            /// Stream start to end
            streams[_id].redeemable =
                (stream.ends - stream.starts) *
                stream.amountPerSec;
            unchecked {
                /// Stream is now inactive
                streams[_id].lastPaid = 0;
                tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
            }
        }
        /// Stream started but has not been updated from before start
        else if (
            /// Stream started
            lastUpdate >= stream.starts &&
            /// Strean not updated after start
            stream.starts > stream.lastPaid
        ) {
            /// Refund payer for:
            /// Stream last updated to stream start
            tokens[stream.token].balance +=
                (stream.starts - stream.lastPaid) *
                stream.amountPerSec;
            /// Payer can redeem:
            /// Stream start to last token update
            streams[_id].redeemable =
                (lastUpdate - stream.starts) *
                stream.amountPerSec;
            unchecked {
                streams[_id].lastPaid = lastUpdate;
            }
        }
        /// Stream has ended
        else if (
            /// Stream ended
            lastUpdate >= stream.ends
        ) {
            /// Refund payer for:
            /// Stream end to last token update
            tokens[stream.token].balance +=
                (lastUpdate - stream.ends) *
                stream.amountPerSec;
            /// Add redeemable for:
            /// Stream last updated to stream end
            streams[_id].redeemable +=
                (stream.ends - stream.lastPaid) *
                stream.amountPerSec;
            /// Stream is now inactive
            unchecked {
                streams[_id].lastPaid = 0;
                tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
            }
        }
        /// Stream is updated before stream starts
        else if (
            /// Stream not started
            stream.starts > lastUpdate
        ) {
            /// Refund payer:
            /// Last stream update to last token update
            tokens[stream.token].balance +=
                (lastUpdate - stream.lastPaid) *
                stream.amountPerSec;
            unchecked {
                /// update lastpaid to last token update
                streams[_id].lastPaid = lastUpdate;
            }
        }
        /// Updated after start, and has not ended
        else if (
            /// Stream started
            stream.lastPaid >= stream.starts &&
            /// Stream has not ended
            stream.ends > lastUpdate
        ) {
            /// Add redeemable for:
            /// stream last update to last token update
            streams[_id].redeemable +=
                (lastUpdate - stream.lastPaid) *
                stream.amountPerSec;
            unchecked {
                streams[_id].lastPaid = lastUpdate;
            }
        }
    }
}
