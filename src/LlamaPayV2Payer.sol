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
error STREAM_HAS_ENDED();

/// @title LlamaPayV2 Payer Contract
/// @author nemusona
contract LlamaPayV2Payer is ERC721, BoringBatchable {
    using SafeTransferLib for ERC20;

    struct Token {
        uint256 balance;
        uint256 totalPaidPerSec;
        uint208 divisor;
        uint48 lastUpdate; /// Overflows when we're all dead
    }

    struct Stream {
        uint208 amountPerSec; /// Can stream 4.11 x 10^42 tokens per sec
        uint48 lastPaid;
        address token;
        uint48 starts;
        uint48 ends;
    }

    address public owner;
    uint256 public nextTokenId;

    mapping(address => Token) public tokens;
    mapping(uint256 => Stream) public streams;
    mapping(address => uint256) public payerWhitelists; /// Allows other addresses to interact on owner behalf
    mapping(uint256 => address) public redirects; /// Allows stream funds to be sent to another address
    mapping(uint256 => mapping(address => uint256)) public streamWhitelists; /// Whitelist for addresses authorized to withdraw from stream
    mapping(uint256 => uint256) public debts; /// Tracks debt for streams
    mapping(uint256 => uint256) public redeemables; /// Tracks redeemable amount for streams

    event Deposit(address token, address from, uint256 amount);
    event WithdrawPayer(address token, address to, uint256 amount);
    event WithdrawPayerAll(address token, address to, uint256 amount);
    event Withdraw(uint256 id, address token, address to, uint256 amount);
    event WithdrawWithRedirect(
        uint256 id,
        address token,
        address to,
        uint256 amount
    );
    event WithdrawAll(uint256 id, address token, address to, uint256 amount);
    event WithdrawAllWithRedirect(
        uint256 id,
        address token,
        address to,
        uint256 amount
    );
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
    event ModifyStream(uint256 id, uint208 newAmountPerSec, uint48 newEnd);
    event StopStream(uint256 id, bool payDebt);
    event ResumeStream(uint256 _id);
    event BurnStream(uint256 _id);
    event AddPayerWhitelist(address whitelisted);
    event RemovePayerWhitelist(address removed);
    event AddRedirectStream(uint256 id, address redirected);
    event RemoveRedirectStream(uint256 id);
    event AddStreamWhitelist(uint256 id, address whitelisted);
    event RemoveStreamWhitelist(uint256 id, address removed);

    constructor() ERC721("LlamaPay V2 Stream", "LLAMAPAY-V2-STREAM") {
        owner = Factory(msg.sender).param(); /// Call factory param to get owner address
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NOT_OWNER();
        _;
    }

    modifier onlyOwnerAndWhitelisted() {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
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
        /// No owner check makes it where people can deposit on behalf
        ERC20 token = ERC20(_token);
        /// Stores token divisor if it is the first time being deposited
        /// Saves on having to call decimals() for conversions afterwards
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
    function withdrawPayer(address _token, uint256 _amount)
        external
        onlyOwnerAndWhitelisted
    {
        /// Update token balance
        /// Makes it where payer cannot rug payee by withdrawing tokens before payee does from stream
        _updateToken(_token);
        uint256 toDeduct = _amount * tokens[_token].divisor;
        /// Will revert if not enough after updating Token
        tokens[_token].balance -= toDeduct;
        ERC20(_token).safeTransfer(msg.sender, _amount);
        emit WithdrawPayer(_token, msg.sender, _amount);
    }

    /// @notice same as above but all available tokens
    /// @param _token token
    function withdrawPayerAll(address _token) external onlyOwnerAndWhitelisted {
        _updateToken(_token);
        Token storage token = tokens[_token];
        uint256 toSend = token.balance / token.divisor;
        tokens[_token].balance = 0;
        ERC20(_token).safeTransfer(msg.sender, toSend);
        emit WithdrawPayerAll(_token, msg.sender, toSend);
    }

    /// @notice withdraw from stream
    /// @param _id token id
    /// @param _amount amount (native decimals)
    function withdraw(uint256 _id, uint256 _amount) external {
        address nftOwner = ownerOf(_id);
        if (
            msg.sender != nftOwner &&
            msg.sender != owner &&
            streamWhitelists[_id][msg.sender] != 1
        ) revert NOT_OWNER_OR_WHITELISTED();

        /// Update stream to update available balances
        _updateStream(_id);
        Stream storage stream = streams[_id];

        /// Reverts if payee is going to rug
        redeemables[_id] -= _amount * tokens[stream.token].divisor;

        ERC20(stream.token).safeTransfer(nftOwner, _amount);
        emit Withdraw(_id, stream.token, nftOwner, _amount);
    }

    /// @notice withdraw all from stream
    /// @param _id token id
    function withdrawAll(uint256 _id) external {
        address nftOwner = ownerOf(_id);
        if (
            msg.sender != nftOwner &&
            msg.sender != owner &&
            streamWhitelists[_id][msg.sender] != 1
        ) revert NOT_OWNER_OR_WHITELISTED();

        /// Update stream to update available balances
        _updateStream(_id);
        Stream storage stream = streams[_id];

        uint256 toRedeem = redeemables[_id] / tokens[stream.token].divisor;
        redeemables[_id] = 0;
        ERC20(stream.token).safeTransfer(nftOwner, toRedeem);
        emit WithdrawAll(_id, stream.token, nftOwner, toRedeem);
    }

    /// @notice withdraw from stream redirect
    /// @param _id token id
    /// @param _amount amount (native decimals)
    function withdrawWithRedirect(uint256 _id, uint256 _amount) external {
        address nftOwner = ownerOf(_id);
        if (
            msg.sender != nftOwner &&
            msg.sender != owner &&
            streamWhitelists[_id][msg.sender] != 1
        ) revert NOT_OWNER_OR_WHITELISTED();

        /// Update stream to update available balances
        _updateStream(_id);
        Stream storage stream = streams[_id];

        /// Reverts if payee is going to rug
        redeemables[_id] -= _amount * tokens[stream.token].divisor;

        address to;
        address redirect = redirects[_id];
        if (redirect != address(0)) {
            to = redirect;
        } else {
            to = nftOwner;
        }

        ERC20(stream.token).safeTransfer(to, _amount);
        emit WithdrawAllWithRedirect(_id, stream.token, to, _amount);
    }

    /// @notice withdraw all from stream redirect
    /// @param _id token id
    function withdrawAllWithRedirect(uint256 _id) external {
        address nftOwner = ownerOf(_id);
        if (
            msg.sender != nftOwner &&
            msg.sender != owner &&
            streamWhitelists[_id][msg.sender] != 1
        ) revert NOT_OWNER_OR_WHITELISTED();

        /// Update stream to update available balances
        _updateStream(_id);
        Stream storage stream = streams[_id];

        /// Reverts if payee is going to rug
        uint256 toRedeem = redeemables[_id] / tokens[stream.token].divisor;

        address to;
        address redirect = redirects[_id];
        if (redirect != address(0)) {
            to = redirect;
        } else {
            to = nftOwner;
        }

        ERC20(stream.token).safeTransfer(to, toRedeem);
        emit WithdrawAllWithRedirect(_id, stream.token, to, toRedeem);
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
    /// @param _newEnd new end time
    function modifyStream(
        uint256 _id,
        uint208 _newAmountPerSec,
        uint48 _newEnd
    ) external onlyOwnerAndWhitelisted {
        _updateStream(_id);
        Stream storage stream = streams[_id];
        /// Prevents people from setting end to time already "paid out"
        if (tokens[stream.token].lastUpdate >= _newEnd) revert INVALID_TIME();

        if (stream.lastPaid > 0) {
            tokens[stream.token].totalPaidPerSec += _newAmountPerSec;
            unchecked {
                tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
            }
        }
        streams[_id].amountPerSec = _newAmountPerSec;
        streams[_id].ends = _newEnd;
        emit ModifyStream(_id, _newAmountPerSec, _newEnd);
    }

    /// @notice Stops current stream
    /// @param _id token id
    /// @param _payDebt choose to pay debt
    function stopStream(uint256 _id, bool _payDebt)
        external
        onlyOwnerAndWhitelisted
    {
        _updateStream(_id);
        Stream storage stream = streams[_id];
        if (stream.lastPaid == 0) revert INACTIVE_STREAM();

        unchecked {
            /// If chooses to pay debt
            if (_payDebt) {
                /// Track owed until stopStream call
                debts[_id] +=
                    (block.timestamp - tokens[stream.token].lastUpdate) *
                    stream.amountPerSec;
            }
            streams[_id].lastPaid = 0;
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }
        emit StopStream(_id, _payDebt);
    }

    /// @notice resumes a stopped stream
    /// @param _id token id
    function resumeStream(uint256 _id) external onlyOwnerAndWhitelisted {
        _updateStream(_id);
        Stream storage stream = streams[_id];
        if (stream.lastPaid > 0) revert ACTIVE_STREAM();
        if (block.timestamp >= stream.ends) revert STREAM_HAS_ENDED();
        if (block.timestamp > tokens[stream.token].lastUpdate)
            revert PAYER_IN_DEBT();

        tokens[stream.token].totalPaidPerSec += stream.amountPerSec;
        unchecked {
            streams[_id].lastPaid = uint48(block.timestamp);
        }
        emit ResumeStream(_id);
    }

    /// @notice burns an inactive and withdrawn stream
    /// @param _id token id
    function burnStream(uint256 _id) external {
        if (
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            msg.sender != ownerOf(_id)
        ) revert NOT_OWNER_OR_WHITELISTED();
        /// Prevents somebody from burning an active stream or a stream with balance in it
        if (redeemables[_id] > 0 || streams[_id].lastPaid > 0)
            revert STREAM_ACTIVE_OR_REDEEMABLE();

        _burn(_id);
        emit BurnStream(_id);
    }

    /// @notice manually update stream
    /// @param _id token id
    function updateStream(uint256 _id) external onlyOwnerAndWhitelisted {
        _updateStream(_id);
    }

    /// @notice repay debt
    /// @param _id token id
    /// @param _amount amount to repay (20 decimals)
    function repayDebt(uint256 _id, uint256 _amount) external {
        if (
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            msg.sender != ownerOf(_id)
        ) revert NOT_OWNER_OR_WHITELISTED();
        address token = streams[_id].token;

        /// Update token to update balances
        _updateToken(token);
        /// Reverts if debt cannot be paid
        tokens[token].balance -= _amount;
        /// Reverts if paying too much debt
        debts[_id] -= _amount;
        /// Add to redeemable to payee
        redeemables[_id] += _amount;
    }

    /// @notice attempt to repay all debt
    /// @param _id token id
    function repayAllDebt(uint256 _id) external {
        if (
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            msg.sender != ownerOf(_id)
        ) revert NOT_OWNER_OR_WHITELISTED();
        address token = streams[_id].token;

        /// Update token to update balances
        _updateToken(token);
        uint256 totalDebt = debts[_id];
        uint256 balance = tokens[token].balance;
        uint256 toPay;
        unchecked {
            if (balance >= totalDebt) {
                tokens[token].balance -= totalDebt;
                debts[_id] = 0;
                toPay = totalDebt;
            } else {
                debts[_id] = totalDebt - balance;
                tokens[token].balance = 0;
                toPay = balance;
            }
        }
        redeemables[_id] += toPay;
    }

    /// Cancel debt from stream
    /// @param _id token id
    function cancelDebt(uint256 _id) external onlyOwnerAndWhitelisted {
        debts[_id] = 0;
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
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        redirects[_id] = _redirectTo;
        emit AddRedirectStream(_id, _redirectTo);
    }

    /// @notice remove redirect to stream
    /// @param _id token id
    function removeRedirectStream(uint256 _id) external {
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        redirects[_id] = address(0);
        emit RemoveRedirectStream(_id);
    }

    /// @notice add whitelist to stream
    /// @param _id token id
    /// @param _toAdd address to whitelist
    function addStreamWhitelist(uint256 _id, address _toAdd) external {
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        streamWhitelists[_id][_toAdd] = 1;
        emit AddStreamWhitelist(_id, _toAdd);
    }

    /// @notice remove whitelist to stream
    /// @param _id token id
    /// @param _toRemove address to remove from whitelist
    function removeStreamWhitelist(uint256 _id, address _toRemove) external {
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        streamWhitelists[_id][_toRemove] = 0;
        emit RemoveStreamWhitelist(_id, _toRemove);
    }

    /// @notice view only function to see withdrawable
    /// @param _id token id
    /// @return lastUpdate last time Token has been updated
    /// @return debt debt owed to stream (native decimals)
    /// @return withdrawableAmount amount withdrawable by payee (native decimals)
    function withdrawable(uint256 _id)
        public
        view
        returns (
            uint256 lastUpdate,
            uint256 debt,
            uint256 withdrawableAmount
        )
    {
        Stream storage stream = streams[_id];
        Token storage token = tokens[stream.token];
        uint256 streamed = (block.timestamp - lastUpdate) *
            token.totalPaidPerSec;

        if (token.balance >= streamed) {
            lastUpdate = block.timestamp;
        } else {
            lastUpdate =
                token.lastUpdate +
                (token.balance / token.totalPaidPerSec);
        }

        /// Inactive or cancelled stream
        if (stream.lastPaid == 0 || stream.starts > block.timestamp) {}
        /// Stream not updated after start and has ended
        else if (
            stream.starts > stream.lastPaid && block.timestamp >= stream.ends
        ) {
            /// if payer is in debt
            if (stream.ends > lastUpdate) {
                debt = (stream.ends - lastUpdate) * stream.amountPerSec;
                withdrawableAmount =
                    (lastUpdate - stream.starts) *
                    stream.amountPerSec;
            } else {
                withdrawableAmount =
                    (stream.ends - stream.starts) *
                    stream.amountPerSec;
            }
        }
        /// Stream started but has not been updated from before start
        else if (
            block.timestamp >= stream.starts && stream.starts > stream.lastPaid
        ) {
            /// if in debt before stream start
            if (stream.starts > lastUpdate) {
                debt = (block.timestamp - stream.starts) * stream.amountPerSec;
            } else {
                withdrawableAmount =
                    (lastUpdate - stream.starts) *
                    stream.amountPerSec;
                debt = (block.timestamp - lastUpdate) * stream.amountPerSec;
            }
        }
        /// Stream has ended
        else if (block.timestamp >= stream.ends) {
            /// If in debt
            if (stream.ends > lastUpdate) {
                debt = (stream.ends * lastUpdate) * stream.amountPerSec;
                withdrawableAmount =
                    (lastUpdate - stream.lastPaid) *
                    stream.amountPerSec;
            } else {
                withdrawableAmount =
                    (stream.ends - stream.lastPaid) *
                    stream.amountPerSec;
            }
        }
        /// Updated after start, and has not ended
        else if (
            stream.lastPaid >= stream.starts && stream.ends > block.timestamp
        ) {
            withdrawableAmount =
                (lastUpdate - stream.lastPaid) *
                stream.amountPerSec;
            debt = (block.timestamp - lastUpdate) * stream.amountPerSec;
        }
        withdrawableAmount =
            (withdrawableAmount + redeemables[_id]) /
            token.divisor;
        debt = debt / token.divisor;
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
        if (_starts >= _ends) revert INVALID_TIME();
        _updateToken(_token);
        Token storage token = tokens[_token];
        if (block.timestamp > token.lastUpdate) revert PAYER_IN_DEBT();

        id = nextTokenId;
        _safeMint(_to, id);

        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            token: _token,
            lastPaid: 0,
            starts: _starts,
            ends: _ends
        });

        /// calculate owed if stream already ended on creation
        uint256 owed;
        if (block.timestamp > _ends) {
            owed = (_ends - _starts) * _amountPerSec;
        }
        /// calculated owed if start is before block.timestamp
        else if (block.timestamp > _starts) {
            owed = (block.timestamp - _starts) * _amountPerSec;
            tokens[_token].totalPaidPerSec += _amountPerSec;
            streams[id].lastPaid = uint48(block.timestamp);
            /// If started at timestamp or starts in the future
        } else if (_starts >= block.timestamp) {
            tokens[_token].totalPaidPerSec += _amountPerSec;
            streams[id].lastPaid = uint48(block.timestamp);
        }

        unchecked {
            /// If can pay owed then directly send it to payee
            if (token.balance >= owed) {
                tokens[_token].balance -= owed;
                redeemables[id] = owed;
            } else {
                /// If cannot pay debt, then add to debt and send entire balance to payee
                uint256 balance = token.balance;
                tokens[_token].balance = 0;
                debts[id] = owed - balance;
                redeemables[id] = balance;
            }
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
        unchecked {
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
                redeemables[_id] =
                    (stream.ends - stream.starts) *
                    stream.amountPerSec;
                /// Stream is now inactive
                streams[_id].lastPaid = 0;
                tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
            }
            /// Stream started but has not been updated from after start
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
                redeemables[_id] =
                    (lastUpdate - stream.starts) *
                    stream.amountPerSec;
                streams[_id].lastPaid = lastUpdate;
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
                redeemables[_id] +=
                    (stream.ends - stream.lastPaid) *
                    stream.amountPerSec;
                /// Stream is now inactive
                streams[_id].lastPaid = 0;
                tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
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
                /// update lastpaid to last token update
                streams[_id].lastPaid = lastUpdate;
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
                redeemables[_id] +=
                    (lastUpdate - stream.lastPaid) *
                    stream.amountPerSec;
                streams[_id].lastPaid = lastUpdate;
            }
        }
    }
}
