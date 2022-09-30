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
error DESTINATION_NOT_WHITELISTED();
error AMOUNT_NOT_AVAILABLE();
error PAYER_IN_DEBT();
error INACTIVE_STREAM();
error ACTIVE_STREAM();
error NOT_OWNER();
error ZERO_ADDRESS();

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
        uint256 amountPerSec;
        address token;
        uint88 paidUpTo;
        bool active;
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
        uint256 amountPerSec
    );
    event CreateStreamWithheld(
        uint256 id,
        address token,
        address to,
        uint256 amountPerSec,
        uint256 withhheldPerSec
    );
    event CancelStream(uint256 id);
    event ModifyStream(uint256 id, uint256 newAmountPerSec);
    event ResumeStream(uint256 id);
    event PauseStream(uint256 id);

    constructor() ERC721("LlamaPayV2 Stream", "LLAMAPAYV2-STREAM") {
        factory = msg.sender;
        owner = Factory(msg.sender).param();
    }

    /// @notice update token balance
    /// @param _token token to be updated
    function _update(address _token) private {
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

    /// @notice deposit into vault
    /// @param _token token to deposit
    /// @param _amount amount to deposit (native decimal)
    function deposit(address _token, uint256 _amount) external {
        ERC20 token = ERC20(_token);
        if (tokens[_token].divisor == 0) {
            tokens[_token].divisor = uint216(10**(20 - token.decimals()));
        }
        tokens[_token].balance += _amount * tokens[_token].divisor;
        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(_token, msg.sender, _amount);
    }

    /// @notice withdraw unstreamed tokens
    /// @param _token token to withdraw
    /// @param _amount amount to withdraw (20 decimals)
    function withdrawPayer(
        address _token,
        address _to,
        uint256 _amount
    ) external {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        if (payerWhitelists[_to] != 1) DESTINATION_NOT_WHITELISTED();
        if (_to == address(0)) revert ZERO_ADDRESS();

        _update(_token);
        tokens[_token].balance -= _amount;

        ERC20 token = ERC20(_token);
        uint256 toWithdraw;
        unchecked {
            toWithdraw = _amount / tokens[_token].divisor;
        }
        token.safeTransfer(_to, toWithdraw);
        emit WithdrawPayer(_token, _to, _amount);
    }

    /// @notice withdraw from stream
    /// @param _id token id
    /// @param _amount amount to withdraw (20 decimals)
    function _withdraw(uint256 _id, uint256 _amount)
        private
        returns (
            ERC20 token,
            address transferTo,
            uint256 toWithdraw
        )
    {
        Stream storage stream = streams[_id];
        address nftOwner = ownerOf(_id);

        if (
            msg.sender != nftOwner &&
            Factory(factory).withdrawalWhitelists(nftOwner, msg.sender) != 1 &&
            msg.sender != owner
        ) revert NOT_OWNER_OR_WHITELISTED();

        _update(stream.token);

        if (stream.redeemable >= _amount) {
            unchecked {
                streams[_id].redeemable -= _amount;
            }
        } else if (!stream.active) {
            revert AMOUNT_NOT_AVAILABLE();
        } else {
            uint256 delta = tokens[stream.token].lastUpdate - stream.paidUpTo;
            uint256 available = (delta * stream.amountPerSec) +
                stream.redeemable;
            if (_amount > available) revert AMOUNT_NOT_AVAILABLE();
            unchecked {
                streams[_id].paidUpTo += uint88(
                    (_amount - stream.redeemable) / stream.amountPerSec
                );
                if (stream.redeemable > 0) {
                    streams[_id].redeemable = 0;
                }
            }
        }

        unchecked {
            toWithdraw = _amount / tokens[stream.token].divisor;
        }

        token = ERC20(stream.token);
        address redirect = Factory(factory).redirects(nftOwner);

        if (redirect != address(0)) {
            transferTo = redirect;
        } else {
            transferTo = nftOwner;
        }
    }

    /// @notice withdraw from stream
    /// @param _id token id
    /// @param _amount amount to withdraw (20 decimals)
    function withdraw(uint256 _id, uint256 _amount) external {
        (ERC20 token, address transferTo, uint256 toWithdraw) = _withdraw(
            _id,
            _amount
        );
        token.safeTransfer(transferTo, toWithdraw);
        emit Withdraw(_id, address(token), transferTo, toWithdraw);
    }

    /// @notice create a stream
    /// @param _token token to stream
    /// @param _to to mint token to
    /// @param _amountPerSec tokens to stream per sec (20 decimals)
    function _createStream(
        address _token,
        address _to,
        uint256 _amountPerSec
    ) private returns (uint256 id) {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        if (_to == address(0)) revert ZERO_ADDRESS();

        _update(_token);

        if (block.timestamp > tokens[_token].lastUpdate) revert PAYER_IN_DEBT();

        tokens[_token].totalPaidPerSec += _amountPerSec;

        id = tokenId;
        _safeMint(_to, id);

        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            token: _token,
            paidUpTo: uint88(block.timestamp),
            active: true,
            redeemable: 0
        });

        unchecked {
            tokenId++;
        }
    }

    /// @notice create a stream
    /// @param _token token to stream
    /// @param _to to mint token to
    /// @param _amountPerSec tokens to stream per sec (20 decimals)
    function createStream(
        address _token,
        address _to,
        uint256 _amountPerSec
    ) external {
        uint256 id = _createStream(_token, _to, _amountPerSec);
        emit CreateStream(id, _token, _to, _amountPerSec);
    }

    /// @notice create stream with withheld event
    /// @param _token token to stream
    /// @param _to to mint token to
    /// @param _amountPerSec tokens to stream per sec (20 decimals)
    /// @param _withheldPerSec withheld per sec for tax withholding (20 decimals)
    function createStreamWithheld(
        address _token,
        address _to,
        uint256 _amountPerSec,
        uint256 _withheldPerSec
    ) external {
        uint256 id = _createStream(_token, _to, _amountPerSec);
        emit CreateStreamWithheld(
            id,
            _token,
            _to,
            _amountPerSec,
            _withheldPerSec
        );
    }

    /// @notice cancel stream
    /// @param _id token id
    function cancelStream(uint256 _id) external {
        Stream storage stream = streams[_id];

        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        if (!stream.active) revert INACTIVE_STREAM();

        uint256 delta = tokens[stream.token].lastUpdate - stream.paidUpTo;
        uint256 available = delta * stream.amountPerSec;

        unchecked {
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }

        streams[_id].active = false;
        streams[_id].redeemable += available;

        emit CancelStream(_id);
    }

    /// @notice modify stream
    /// @param _id token id
    /// @param _newAmountPerSec new amount per sec (20 decimals)
    function modifyStream(uint256 _id, uint256 _newAmountPerSec) external {
        Stream storage stream = streams[_id];

        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        if (!stream.active) revert INACTIVE_STREAM();

        _update(stream.token);

        uint256 delta = tokens[stream.token].lastUpdate - stream.paidUpTo;
        uint256 available = delta * stream.amountPerSec;

        tokens[stream.token].totalPaidPerSec += _newAmountPerSec;
        unchecked {
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }

        streams[_id].amountPerSec = _newAmountPerSec;
        streams[_id].redeemable += available;
        unchecked {
            streams[_id].paidUpTo = uint88(block.timestamp);
        }

        emit ModifyStream(_id, _newAmountPerSec);
    }

    /// @notice pause stream
    /// @param _id token id
    function pauseStream(uint256 _id) external {
        Stream storage stream = streams[_id];

        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        if (!stream.active) revert INACTIVE_STREAM();

        _update(stream.token);

        uint256 delta = tokens[stream.token].lastUpdate - stream.paidUpTo;
        uint256 available = delta * stream.amountPerSec;

        streams[_id].redeemable += available;
        streams[_id].active = false;

        unchecked {
            tokens[stream.token].totalPaidPerSec -= stream.amountPerSec;
        }

        emit PauseStream(_id);
    }

    /// @notice resume stream
    /// @param _id token id
    function resumeStream(uint256 _id) external {
        Stream storage stream = streams[_id];

        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
        if (stream.active) revert ACTIVE_STREAM();

        _update(stream.token);

        if (block.timestamp > tokens[stream.token].lastUpdate)
            revert PAYER_IN_DEBT();

        streams[_id].paidUpTo = uint88(block.timestamp);
        tokens[stream.token].totalPaidPerSec += stream.amountPerSec;

        emit ResumeStream(_id);
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

    /// @notice withdrawable from stream
    /// @param _id token id
    /// @return withdrawableAmount wihtdrawable amount (20 decimals)
    function withdrawable(uint256 _id)
        public
        view
        returns (
            uint256 withdrawableAmount,
            uint256 debt,
            uint256 lastPayerUpdate
        )
    {
        Stream storage stream = streams[_id];
        Token storage token = tokens[stream.token];

        uint256 delta = block.timestamp - token.lastUpdate;
        uint256 totalStreamed = delta * token.totalPaidPerSec;

        if (token.balance >= totalStreamed) {
            lastPayerUpdate = block.timestamp;
        } else {
            lastPayerUpdate =
                token.lastUpdate +
                (token.balance / token.totalPaidPerSec);
        }
        uint256 streamDelta = lastPayerUpdate - stream.paidUpTo;
        withdrawableAmount =
            (streamDelta * stream.amountPerSec) +
            stream.redeemable;
        debt = (block.timestamp - lastPayerUpdate) * stream.amountPerSec;
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
}
