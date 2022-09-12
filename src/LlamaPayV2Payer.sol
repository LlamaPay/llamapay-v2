//SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.16;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "./BoringBatchable.sol";

interface Factory {
    function param() external returns (address);
}

error NOT_OWNER();
error OWNER_IS_ZERO();
error STREAM_PAUSED_OR_CANCELLED();
error STREAM_ACTIVE();
error AMOUNT_NOT_AVAILABLE();
error PAYER_IN_DEBT();

/// @title LlamaPayV2 Payer Contract
/// @author nemusona
contract LlamaPayV2Payer is ERC721, BoringBatchable {
    using SafeTransferLib for ERC20;

    struct Token {
        uint256 balance;
        uint40 lastUpdate;
        uint216 totalPaidPerSec;
    }

    struct Stream {
        uint256 amountPerSec;
        address token;
        uint96 paidUpTo;
    }

    address public immutable factory;
    address public immutable owner;
    uint256 public tokenId;

    mapping(address => Token) tokens;
    mapping(uint256 => Stream) streams;

    event Deposit(address token, address from, uint256 amount);
    event WithdrawPayer(address token, uint256 amount);
    event Withdraw(uint256 id, address token, address to, uint256 amount);
    event CreateStream(
        uint256 id,
        address token,
        address to,
        uint256 amountPerSec
    );
    event CancelStream(uint256 id);
    event ModifyStream(uint256 id, address newToken, uint256 newAmountPerSec);
    event ResumeStream(uint256 id);
    event PauseStream(uint256 id);

    constructor() ERC721("LlamaPayV2 Stream", "LLAMAPAYV2-STREAM") {
        factory = msg.sender;
        owner = Factory(msg.sender).param();
        tokenId = 1;
    }

    /// @notice update token balance
    /// @param _token token to be updated
    function _update(address _token) private {
        Token storage token = tokens[_token];
        uint256 delta = block.timestamp - token.lastUpdate;

        unchecked {
            uint256 streamed = delta * token.totalPaidPerSec;
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
        tokens[_token].balance += _amount * (10**(20 - token.decimals()));
        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(_token, msg.sender, _amount);
    }

    /// @notice withdraw unstreamed tokens
    /// @param _token token to withdraw
    /// @param _amount amount to withdraw (20 decimals)
    function withdrawPayer(address _token, uint256 _amount) external {
        if (msg.sender != owner) revert NOT_OWNER();

        _update(_token);
        tokens[_token].balance -= _amount;

        ERC20 token = ERC20(_token);
        uint256 toWithdraw;
        unchecked {
            toWithdraw = _amount / (10**(20 - token.decimals()));
        }
        token.safeTransfer(msg.sender, toWithdraw);
        emit WithdrawPayer(_token, toWithdraw);
    }

    /// @notice withdraw from stream
    /// @param _id token id
    /// @param _amount amount to withdraw (20 decimals)
    function withdraw(uint256 _id, uint256 _amount) public {
        Stream storage stream = streams[_id];
        address to = ownerOf(_id);
        if (to == address(0)) revert OWNER_IS_ZERO();
        if (stream.amountPerSec == 0) revert STREAM_PAUSED_OR_CANCELLED();

        _update(stream.token);

        uint256 delta = tokens[stream.token].lastUpdate - stream.paidUpTo;
        uint256 available = delta * stream.amountPerSec;
        if (_amount > available) revert AMOUNT_NOT_AVAILABLE();

        unchecked {
            streams[_id].paidUpTo += uint40(_amount / stream.amountPerSec);
        }

        ERC20 token = ERC20(stream.token);

        uint256 toWithdraw;
        unchecked {
            toWithdraw = _amount * (10**(20 - token.decimals()));
        }
        token.safeTransfer(to, toWithdraw);

        emit Withdraw(_id, stream.token, to, toWithdraw);
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
        if (msg.sender != owner) revert NOT_OWNER();
        if (_to == address(0)) revert OWNER_IS_ZERO();

        _update(_token);
        if (block.timestamp > tokens[_token].lastUpdate) revert PAYER_IN_DEBT();

        tokens[_token].totalPaidPerSec += uint216(_amountPerSec);

        uint256 id = tokenId;
        _safeMint(_to, id);

        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            token: _token,
            paidUpTo: uint96(block.timestamp)
        });

        unchecked {
            tokenId++;
        }

        emit CreateStream(id, _token, _to, _amountPerSec);
    }

    /// @notice cancel stream
    /// @param _id token id
    function cancelStream(uint256 _id) external {
        Stream storage stream = streams[_id];
        if (msg.sender != owner) revert NOT_OWNER();
        if (stream.amountPerSec == 0) revert STREAM_PAUSED_OR_CANCELLED();

        (uint256 withdrawableAmount, , ) = withdrawable(_id);
        withdraw(_id, withdrawableAmount);

        unchecked {
            tokens[stream.token].totalPaidPerSec -= uint216(
                streams[_id].amountPerSec
            );
        }

        _burn(_id);
        streams[_id] = Stream({
            amountPerSec: 0,
            token: address(0),
            paidUpTo: 0
        });

        emit CancelStream(_id);
    }

    /// @notice modify stream
    /// @param _id token id
    /// @param _newToken new token
    /// @param _newAmountPerSec new amount per sec (20 decimals)
    function modifyStream(
        uint256 _id,
        address _newToken,
        uint256 _newAmountPerSec
    ) external {
        Stream storage stream = streams[_id];
        if (msg.sender != owner) revert NOT_OWNER();
        if (stream.amountPerSec == 0) revert STREAM_PAUSED_OR_CANCELLED();

        (uint256 withdrawableAmount, , ) = withdrawable(_id);
        withdraw(_id, withdrawableAmount);

        unchecked {
            tokens[stream.token].totalPaidPerSec -= uint216(
                stream.amountPerSec
            );
        }

        _update(_newToken);
        if (block.timestamp > tokens[_newToken].lastUpdate)
            revert PAYER_IN_DEBT();

        tokens[_newToken].totalPaidPerSec += uint216(_newAmountPerSec);

        streams[_id] = Stream({
            amountPerSec: _newAmountPerSec,
            token: _newToken,
            paidUpTo: uint96(block.timestamp)
        });

        emit ModifyStream(_id, _newToken, _newAmountPerSec);
    }

    /// @notice pause stream
    /// @param _id token id
    function pauseStream(uint256 _id) external {
        Stream storage stream = streams[_id];
        if (msg.sender != owner) revert NOT_OWNER();
        if (stream.paidUpTo == 0) revert STREAM_PAUSED_OR_CANCELLED();

        (uint256 withdrawableAmount, , ) = withdrawable(_id);
        withdraw(_id, withdrawableAmount);

        unchecked {
            tokens[stream.token].totalPaidPerSec -= uint216(
                stream.amountPerSec
            );
            streams[_id].paidUpTo = 0;
        }
        emit PauseStream(_id);
    }

    /// @notice resume stream
    /// @param _id token id
    function resumeStream(uint256 _id) external {
        Stream storage stream = streams[_id];
        if (msg.sender != owner) revert NOT_OWNER();
        if (ownerOf(_id) == address(0)) revert OWNER_IS_ZERO();
        if (stream.paidUpTo > 0) revert STREAM_ACTIVE();

        _update(stream.token);
        if (block.timestamp > tokens[stream.token].lastUpdate)
            revert PAYER_IN_DEBT();

        streams[_id].paidUpTo = uint40(block.timestamp);
        tokens[stream.token].totalPaidPerSec += uint216(stream.amountPerSec);

        emit ResumeStream(_id);
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
        withdrawableAmount = (streamDelta * stream.amountPerSec);
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
