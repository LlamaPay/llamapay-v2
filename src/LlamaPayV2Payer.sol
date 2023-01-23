// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";
import "./forks/BoringBatchable.sol";

interface Factory {
    function param() external view returns (address);
}

error NOT_OWNER();
error NOT_OWNER_OR_WHITELISTED();
error INVALID_ADDRESS();
error INVALID_TIME();
error PAYER_IN_DEBT();
error INACTIVE_STREAM();
error ACTIVE_STREAM();
error STREAM_ACTIVE_OR_REDEEMABLE();
error STREAM_ENDED();
error STREAM_DOES_NOT_EXIST();
error TOKEN_NOT_ADDED();
error INVALID_AMOUNT();
error ALREADY_WHITELISTED();
error NOT_WHITELISTED();

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
    string public constant baseURI = "https://nft.llamapay.io/stream/";
    uint256 public nextTokenId;

    mapping(address => Token) public tokens;
    mapping(uint256 => Stream) public streams;
    mapping(address => uint256) public payerWhitelists; /// Allows other addresses to interact on owner behalf
    mapping(address => mapping(uint256 => address)) public redirects; /// Allows stream funds to be sent to another address
    mapping(address => mapping(uint256 => mapping(address => uint256)))
        public streamWhitelists; /// Whitelist for addresses authorized to withdraw from stream
    mapping(uint256 => uint256) public debts; /// Tracks debt for streams
    mapping(uint256 => uint256) public redeemables; /// Tracks redeemable amount for streams

    event Deposit(address indexed token, address indexed from, uint256 amount);
    event WithdrawPayer(
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event WithdrawPayerAll(
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event Withdraw(
        uint256 id,
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event WithdrawWithRedirect(
        uint256 id,
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event WithdrawAll(
        uint256 id,
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event WithdrawAllWithRedirect(
        uint256 id,
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event CreateStream(
        uint256 id,
        address indexed token,
        address indexed to,
        uint256 amountPerSec,
        uint48 starts,
        uint48 ends
    );
    event ModifyStream(uint256 id, uint208 newAmountPerSec, uint48 newEnd);
    event StopStream(uint256 id);
    event ResumeStream(uint256 id);
    event BurnStream(uint256 id);
    event AddPayerWhitelist(address indexed whitelisted);
    event RemovePayerWhitelist(address indexed removed);
    event AddRedirectStream(uint256 id, address indexed redirected);
    event RemoveRedirectStream(uint256 id);
    event AddStreamWhitelist(uint256 id, address indexed whitelisted);
    event RemoveStreamWhitelist(uint256 id, address indexed removed);
    event UpdateToken(address indexed token);
    event UpdateStream(uint256 id);
    event RepayDebt(uint256 id, uint256 amount);
    event RepayAllDebt(uint256 id, uint256 amount);

    constructor() ERC721("LlamaPay V2 Stream", "LLAMAPAY-V2-STREAM") {
        owner = Factory(msg.sender).param(); /// Call factory param to get owner address
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NOT_OWNER();
        _;
    }

    modifier onlyOwnerOrWhitelisted() {
        if (msg.sender != owner && payerWhitelists[msg.sender] != 1)
            revert NOT_OWNER_OR_WHITELISTED();
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
        tokens[_token].balance += _amount * uint256(tokens[_token].divisor);
        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(_token, msg.sender, _amount);
    }

    /// @notice withdraw tokens that have not been streamed yet
    /// @param _token token
    /// @param _amount amount (native token decimals)
    function withdrawPayer(address _token, uint256 _amount)
        external
        onlyOwnerOrWhitelisted
    {
        /// Update token balance
        /// Makes it where payer cannot rug payee by withdrawing tokens before payee does from stream
        _updateToken(_token);
        uint256 toDeduct = _amount * uint256(tokens[_token].divisor);
        /// Will revert if not enough after updating Token
        tokens[_token].balance -= toDeduct;
        ERC20(_token).safeTransfer(msg.sender, _amount);
        emit WithdrawPayer(_token, msg.sender, _amount);
    }

    /// @notice same as above but all available tokens
    /// @param _token token
    function withdrawPayerAll(address _token) external onlyOwnerOrWhitelisted {
        Token storage token = _updateToken(_token);
        uint256 toSend = token.balance / uint256(token.divisor);
        tokens[_token].balance = 0;
        ERC20(_token).safeTransfer(msg.sender, toSend);
        emit WithdrawPayerAll(_token, msg.sender, toSend);
    }

    /// @notice withdraw from stream
    /// @param _id token id
    /// @param _amount amount (native decimals)
    function withdraw(uint256 _id, uint256 _amount) external {
        address nftOwner = ownerOrNftOwnerOrWhitelisted(_id);

        /// Update stream to update available balances
        Stream storage stream = _updateStream(_id);

        /// Reverts if payee is going to rug
        redeemables[_id] -= _amount * uint256(tokens[stream.token].divisor);

        ERC20(stream.token).safeTransfer(nftOwner, _amount);
        emit Withdraw(_id, stream.token, nftOwner, _amount);
    }

    /// @notice withdraw all from stream
    /// @param _id token id
    function withdrawAll(uint256 _id) external {
        address nftOwner = ownerOrNftOwnerOrWhitelisted(_id);

        /// Update stream to update available balances
        Stream storage stream = _updateStream(_id);

        uint256 toRedeem = redeemables[_id] /
            uint256(tokens[stream.token].divisor);
        redeemables[_id] = 0;
        ERC20(stream.token).safeTransfer(nftOwner, toRedeem);
        emit WithdrawAll(_id, stream.token, nftOwner, toRedeem);
    }

    /// @notice withdraw from stream redirect
    /// @param _id token id
    /// @param _amount amount (native decimals)
    function withdrawWithRedirect(uint256 _id, uint256 _amount) external {
        address nftOwner = ownerOrNftOwnerOrWhitelisted(_id);

        /// Update stream to update available balances
        Stream storage stream = _updateStream(_id);

        /// Reverts if payee is going to rug
        redeemables[_id] -= _amount * uint256(tokens[stream.token].divisor);

        address to;
        address redirect = redirects[nftOwner][_id];
        if (redirect == address(0)) {
            to = nftOwner;
        } else {
            to = redirect;
        }

        ERC20(stream.token).safeTransfer(to, _amount);
        emit WithdrawWithRedirect(_id, stream.token, to, _amount);
    }

    /// @notice withdraw all from stream redirect
    /// @param _id token id
    function withdrawAllWithRedirect(uint256 _id) external {
        address nftOwner = ownerOrNftOwnerOrWhitelisted(_id);

        /// Update stream to update available balances
        Stream storage stream = _updateStream(_id);

        /// Reverts if payee is going to rug
        uint256 toRedeem = redeemables[_id] /
            uint256(tokens[stream.token].divisor);
        redeemables[_id] = 0;

        address to;
        address redirect = redirects[nftOwner][_id];
        if (redirect == address(0)) {
            to = nftOwner;
        } else {
            to = redirect;
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

    /// @notice modifies current stream
    /// @param _id token id
    /// @param _newAmountPerSec modified amount per sec (20 decimals)
    /// @param _newEnd new end time
    function modifyStream(
        uint256 _id,
        uint208 _newAmountPerSec,
        uint48 _newEnd
    ) external onlyOwnerOrWhitelisted {
        Stream storage stream = _updateStream(_id);
        if (_newAmountPerSec == 0) revert INVALID_AMOUNT();
        /// Prevents people from setting end to time already "paid out"
        if (tokens[stream.token].lastUpdate >= _newEnd) revert INVALID_TIME();

        /// Check if stream is active
        /// Prevents miscalculation in totalPaidPerSec
        if (stream.lastPaid > 0) {
            tokens[stream.token].totalPaidPerSec += uint256(_newAmountPerSec);
            unchecked {
                tokens[stream.token].totalPaidPerSec -= uint256(
                    stream.amountPerSec
                );
            }
        }
        streams[_id].amountPerSec = _newAmountPerSec;
        streams[_id].ends = _newEnd;
        emit ModifyStream(_id, _newAmountPerSec, _newEnd);
    }

    /// @notice Stops current stream
    /// @param _id token id
    function stopStream(uint256 _id) external onlyOwnerOrWhitelisted {
        Stream storage stream = _updateStream(_id);
        if (stream.lastPaid == 0) revert INACTIVE_STREAM();
        uint256 amountPerSec = uint256(stream.amountPerSec);
        unchecked {
            /// Track owed until stopStream call
            debts[_id] +=
                (block.timestamp - uint256(tokens[stream.token].lastUpdate)) *
                amountPerSec;
            streams[_id].lastPaid = 0;
            tokens[stream.token].totalPaidPerSec -= amountPerSec;
        }
        emit StopStream(_id);
    }

    /// @notice resumes a stopped stream
    /// @param _id token id
    function resumeStream(uint256 _id) external onlyOwnerOrWhitelisted {
        Stream storage stream = _updateStream(_id);
        if (stream.lastPaid > 0) revert ACTIVE_STREAM();
        if (block.timestamp >= stream.ends) revert STREAM_ENDED();
        if (block.timestamp > tokens[stream.token].lastUpdate)
            revert PAYER_IN_DEBT();

        tokens[stream.token].totalPaidPerSec += uint256(stream.amountPerSec);
        streams[_id].lastPaid = uint48(block.timestamp);
        emit ResumeStream(_id);
    }

    /// @notice burns an inactive and withdrawn stream
    /// @param _id token id
    function burnStream(uint256 _id) external {
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        /// Prevents somebody from burning an active stream or a stream with balance in it
        if (redeemables[_id] > 0 || streams[_id].lastPaid > 0 || debts[_id] > 0)
            revert STREAM_ACTIVE_OR_REDEEMABLE();

        /// Free up storage
        delete streams[_id];
        delete debts[_id];
        delete redeemables[_id];
        _burn(_id);
        emit BurnStream(_id);
    }

    /// @notice manually update stream
    /// @param _id token id
    function updateStream(uint256 _id) external onlyOwnerOrWhitelisted {
        _updateStream(_id);
    }

    /// @notice repay debt
    /// @param _id token id
    /// @param _amount amount to repay (native decimals)
    function repayDebt(uint256 _id, uint256 _amount) external {
        ownerOrNftOwnerOrWhitelisted(_id);

        /// Update stream to update balances
        Stream storage stream = _updateStream(_id);
        uint256 toRepay;
        unchecked {
            toRepay = _amount * uint256(tokens[stream.token].divisor);
            /// Add to redeemable to payee
            redeemables[_id] += toRepay;
        }
        /// Reverts if debt cannot be paid
        tokens[stream.token].balance -= toRepay;
        /// Reverts if paying too much debt
        debts[_id] -= toRepay;
        emit RepayDebt(_id, _amount);
    }

    /// @notice attempt to repay all debt
    /// @param _id token id
    function repayAllDebt(uint256 _id) external {
        ownerOrNftOwnerOrWhitelisted(_id);

        /// Update stream to update balances
        Stream storage stream = _updateStream(_id);
        uint256 totalDebt = debts[_id];
        uint256 balance = tokens[stream.token].balance;
        uint256 toPay;
        unchecked {
            if (balance >= totalDebt) {
                tokens[stream.token].balance -= totalDebt;
                debts[_id] = 0;
                toPay = totalDebt;
            } else {
                debts[_id] = totalDebt - balance;
                tokens[stream.token].balance = 0;
                toPay = balance;
            }
        }
        redeemables[_id] += toPay;
        emit RepayAllDebt(_id, toPay / uint256(tokens[stream.token].divisor));
    }

    /// @notice add address to payer whitelist
    /// @param _toAdd address to whitelist
    function addPayerWhitelist(address _toAdd) external onlyOwner {
        if (_toAdd == address(0)) revert INVALID_ADDRESS();
        if (payerWhitelists[_toAdd] == 1) revert ALREADY_WHITELISTED();
        payerWhitelists[_toAdd] = 1;
        emit AddPayerWhitelist(_toAdd);
    }

    /// @notice remove address to payer whitelist
    /// @param _toRemove address to remove from whitelist
    function removePayerWhitelist(address _toRemove) external onlyOwner {
        if (_toRemove == address(0)) revert INVALID_ADDRESS();
        if (payerWhitelists[_toRemove] == 0) revert NOT_WHITELISTED();
        payerWhitelists[_toRemove] = 0;
        emit RemovePayerWhitelist(_toRemove);
    }

    /// @notice add redirect to stream
    /// @param _id token id
    /// @param _redirectTo address to redirect funds to
    function addRedirectStream(uint256 _id, address _redirectTo) external {
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        if (_redirectTo == address(0)) revert INVALID_ADDRESS();
        redirects[msg.sender][_id] = _redirectTo;
        emit AddRedirectStream(_id, _redirectTo);
    }

    /// @notice remove redirect to stream
    /// @param _id token id
    function removeRedirectStream(uint256 _id) external {
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        delete redirects[msg.sender][_id];
        emit RemoveRedirectStream(_id);
    }

    /// @notice add whitelist to stream
    /// @param _id token id
    /// @param _toAdd address to whitelist
    function addStreamWhitelist(uint256 _id, address _toAdd) external {
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        if (_toAdd == address(0)) revert INVALID_ADDRESS();
        if (streamWhitelists[msg.sender][_id][_toAdd] == 1)
            revert ALREADY_WHITELISTED();
        streamWhitelists[msg.sender][_id][_toAdd] = 1;
        emit AddStreamWhitelist(_id, _toAdd);
    }

    /// @notice remove whitelist to stream
    /// @param _id token id
    /// @param _toRemove address to remove from whitelist
    function removeStreamWhitelist(uint256 _id, address _toRemove) external {
        if (_toRemove == address(0)) revert INVALID_ADDRESS();
        if (msg.sender != ownerOf(_id)) revert NOT_OWNER();
        if (streamWhitelists[msg.sender][_id][_toRemove] == 0)
            revert NOT_WHITELISTED();
        streamWhitelists[msg.sender][_id][_toRemove] = 0;
        emit RemoveStreamWhitelist(_id, _toRemove);
    }

    /// @notice view only function to see withdrawable
    /// @param _id token id
    /// @return lastUpdate last time Token has been updated
    /// @return debt debt owed to stream (native decimals)
    /// @return withdrawableAmount amount withdrawable by payee (native decimals)
    function withdrawable(uint256 _id)
        external
        view
        returns (
            uint256 lastUpdate,
            uint256 debt,
            uint256 withdrawableAmount
        )
    {
        Stream storage stream = streams[_id];
        Token storage token = tokens[stream.token];
        uint256 starts = uint256(stream.starts);
        uint256 ends = uint256(stream.ends);
        uint256 amountPerSec = uint256(stream.amountPerSec);
        uint256 divisor = uint256(token.divisor);
        uint256 streamed;
        unchecked {
            streamed = (block.timestamp - lastUpdate) * token.totalPaidPerSec;
        }

        if (token.balance >= streamed) {
            lastUpdate = block.timestamp;
        } else {
            lastUpdate =
                uint256(token.lastUpdate) +
                (token.balance / token.totalPaidPerSec);
        }

        /// Inactive or cancelled stream
        if (stream.lastPaid == 0 || starts > block.timestamp) {
            return (0, 0, 0);
        }

        uint256 start = max(uint256(stream.lastPaid), starts);
        uint256 stop = min(ends, lastUpdate);
        // If lastUpdate isn't block.timestamp and greater than ends, there is debt.
        if (lastUpdate != block.timestamp && ends > lastUpdate) {
            debt =
                (min(block.timestamp, ends) - max(lastUpdate, starts)) *
                amountPerSec;
        }
        withdrawableAmount = (stop - start) * amountPerSec;

        withdrawableAmount = (withdrawableAmount + redeemables[_id]) / divisor;
        debt = (debt + debts[_id]) / divisor;
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
    ) private onlyOwnerOrWhitelisted returns (uint256 id) {
        if (_starts >= _ends) revert INVALID_TIME();
        if (_to == address(0)) revert INVALID_ADDRESS();
        if (_amountPerSec == 0) revert INVALID_AMOUNT();

        Token storage token = _updateToken(_token);
        if (block.timestamp > token.lastUpdate) revert PAYER_IN_DEBT();

        id = nextTokenId;

        /// calculate owed if stream already ended on creation
        uint256 owed;
        uint256 lastPaid;
        uint256 starts = uint256(_starts);
        uint256 amountPerSec = uint256(_amountPerSec);
        if (block.timestamp > _ends) {
            owed = (uint256(_ends) - starts) * amountPerSec;
        }
        /// calculated owed if start is before block.timestamp
        else if (block.timestamp > starts) {
            owed = (block.timestamp - starts) * amountPerSec;
            tokens[_token].totalPaidPerSec += amountPerSec;
            lastPaid = block.timestamp;
            /// If started at timestamp or starts in the future
        } else if (starts >= block.timestamp) {
            tokens[_token].totalPaidPerSec += amountPerSec;
            lastPaid = block.timestamp;
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

        streams[id] = Stream({
            amountPerSec: _amountPerSec,
            token: _token,
            lastPaid: uint48(lastPaid),
            starts: _starts,
            ends: _ends
        });

        _safeMint(_to, id);
    }

    /// @notice updates token balances
    /// @param _token token to update
    function _updateToken(address _token)
        private
        returns (Token storage token)
    {
        token = tokens[_token];
        if (token.divisor == 0) revert TOKEN_NOT_ADDED();
        /// Streamed from last update to called
        unchecked {
            uint256 streamed = (block.timestamp - uint256(token.lastUpdate)) *
                token.totalPaidPerSec;
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
        emit UpdateToken(_token);
    }

    /// @notice update stream
    /// @param _id token id
    function _updateStream(uint256 _id)
        private
        returns (Stream storage stream)
    {
        if (ownerOf(_id) == address(0)) revert STREAM_DOES_NOT_EXIST();
        /// Update Token info to get last update
        stream = streams[_id];
        _updateToken(stream.token);
        unchecked {
            uint256 lastUpdate = uint256(tokens[stream.token].lastUpdate);
            uint256 amountPerSec = uint256(stream.amountPerSec);
            uint256 lastPaid = uint256(stream.lastPaid);
            uint256 starts = uint256(stream.starts);
            uint256 ends = uint256(stream.ends);
            /// If stream is inactive/cancelled
            if (lastPaid == 0) {
                /// Can only withdraw redeemable so do nothing
            }
            /// Stream not updated after start and has ended
            else if (
                /// Stream not updated after start
                starts > lastPaid &&
                /// Stream ended
                lastUpdate >= ends
            ) {
                /// Refund payer for:
                /// Stream last updated to stream start
                /// Stream ended to token last updated
                tokens[stream.token].balance +=
                    ((starts - lastPaid) + (lastUpdate - ends)) *
                    amountPerSec;
                /// Payee can redeem:
                /// Stream start to end
                redeemables[_id] = (ends - starts) * amountPerSec;
                /// Stream is now inactive
                streams[_id].lastPaid = 0;
                tokens[stream.token].totalPaidPerSec -= amountPerSec;
            }
            /// Stream started but has not been updated from after start
            else if (
                /// Stream started
                lastUpdate >= starts &&
                /// Stream not updated after start
                starts > lastPaid
            ) {
                /// Refund payer for:
                /// Stream last updated to stream start
                tokens[stream.token].balance +=
                    (starts - lastPaid) *
                    amountPerSec;
                /// Payer can redeem:
                /// Stream start to last token update
                redeemables[_id] = (lastUpdate - starts) * amountPerSec;
                streams[_id].lastPaid = uint48(lastUpdate);
            }
            /// Stream has ended
            else if (
                /// Stream ended
                lastUpdate >= ends
            ) {
                /// Refund payer for:
                /// Stream end to last token update
                tokens[stream.token].balance +=
                    (lastUpdate - ends) *
                    amountPerSec;
                /// Add redeemable for:
                /// Stream last updated to stream end
                redeemables[_id] += (ends - lastPaid) * amountPerSec;
                /// Stream is now inactive
                streams[_id].lastPaid = 0;
                tokens[stream.token].totalPaidPerSec -= amountPerSec;
            }
            /// Stream is updated before stream starts
            else if (
                /// Stream not started
                starts > lastUpdate
            ) {
                /// Refund payer:
                /// Last stream update to last token update
                tokens[stream.token].balance +=
                    (lastUpdate - lastPaid) *
                    amountPerSec;
                /// update lastpaid to last token update
                streams[_id].lastPaid = uint48(lastUpdate);
            }
            /// Updated after start, and has not ended
            else if (
                /// Stream started
                lastPaid >= starts &&
                /// Stream has not ended
                ends > lastUpdate
            ) {
                /// Add redeemable for:
                /// stream last update to last token update
                redeemables[_id] += (lastUpdate - lastPaid) * amountPerSec;
                streams[_id].lastPaid = uint48(lastUpdate);
            }
        }
        emit UpdateStream(_id);
    }

    function ownerOrNftOwnerOrWhitelisted(uint256 _id)
        internal
        view
        returns (address nftOwner)
    {
        nftOwner = ownerOf(_id);
        if (
            msg.sender != nftOwner &&
            msg.sender != owner &&
            payerWhitelists[msg.sender] != 1 &&
            streamWhitelists[nftOwner][_id][msg.sender] != 1
        ) revert NOT_OWNER_OR_WHITELISTED();
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
