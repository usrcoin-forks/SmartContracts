pragma solidity ^0.4.11;

import "../core/common/Owned.sol";
import "../core/contracts/ContractsManagerInterface.sol";
import "../core/lib/SafeMath.sol";
import "../core/user/UserManagerInterface.sol";
import "../timeholder/TimeHolderInterface.sol";
import "../pending/MultiSigSupporter.sol";
import "./VotingManagerInterface.sol";
import "./PollEmitter.sol";
import "./PollInterface.sol";


/// @title Backend contract is created to reduce size of poll contract and transfer all logic
/// and operations (where it's possible) on a shoulders of this contract. This contract could
/// be updatable through by publishing new poll factory.
///
/// It is not supposed to be registered in ContractsManager.
contract PollBackend is Owned, MultiSigSupporter {
    using SafeMath for uint;

    /** Constants */

    uint8 constant OPTIONS_POLLS_MAX = 16;

    /** Error codes */

    uint constant UNAUTHORIZED = 0;
    uint constant ERROR_POLL_BACKEND_INVALID_INVOCATION = 26001;
    uint constant ERROR_POLL_BACKEND_NO_SHARES = 26002;
    uint constant ERROR_POLL_BACKEND_INVALID_STATE = 26003;
    uint constant ERROR_POLL_BACKEND_ALREADY_VOTED = 26004;

    /// @title Defines finite number of poll's state:
    /// - Prepare - poll is probably initialized and ready to be activated
    /// - Active - poll is active, people could vote and poll could be ended
    /// - Finished - poll is ended and ready to be utilized (killed)
    enum State { Prepare, Active, Finished }

    /**
    * Storage variables. Duplicates @see PollRouter storage layout so
    * DO NOT CHANGE VARIABLES' LAYOUT UNDER ANY CIRCUMSTANCES!
    */

    address internal backendAddress;
    address internal contractsManager;

    bytes32 internal detailsIpfsHash;
    uint internal votelimit;
    uint internal deadline;
    uint internal creation;
    State state = State.Prepare;

    uint internal optionsCount;

    mapping(address => uint8) public memberOptions;
    mapping(address => uint) public memberVotes;
    mapping(uint8 => uint) public optionsBalance;


    /** Modifiers */

    /// @dev Guards invocations only for VotingManager
    modifier onlyVotingManager {
        require(msg.sender == lookupManager("VotingManager"));
        _;
    }

    /// @dev Guards invocations only for authorized (CBE) accounts
    modifier onlyAuthorized {
        if (isAuthorized(msg.sender)) {
            _;
        }
    }

    ///  @notice Initializes internal fields. Contracts owner only.
    ///  @dev Will rollback transaction if something goes wrong during initialization.
    ///  @param _contractsManager is contract manager, must be not 0x0
    ///  @return OK if newly initialized and everything is OK,
    ///  or REINITIALIZED if storage already contains some data. Will crash in any other cases.
    function init(address _contractsManager) onlyContractOwner public returns (uint) {
        require(_contractsManager != 0x0);
        contractsManager = _contractsManager;
    }

    /// @notice Gets if a poll has active status and people still could vote
    function active() public view returns (bool) {
        return state == State.Active;
    }

    /// @notice Returns if _address is authorized (CBE)
    /// @return `true` if access is allowed, `false` otherwise
    function isAuthorized(address _key) public view returns (bool) {
        return UserManagerInterface(lookupManager("UserManager")).getCBE(_key);
    }

    /// @notice Gets owner of a poll
    /// @dev delegatecall only
    function owner() public view returns (address) {
        return contractOwner;
    }

    /// @notice Gets eventsHistory for the manager
    /// @return address of eventsHistory
    function getEventsHistory() public view returns (PollEmitter) {
        return PollEmitter(lookupManager("MultiEventsHistory"));
    }

    /// @notice returns listener to react on PollListenerInterface's actions
    function getPollListener() public view returns (PollListenerInterface) {
        return PollListenerInterface(lookupManager("VotingManager"));
    }

    /// @notice Checks if a user is participating in the poll
    /// @dev delegatecall only
    /// @param _user address of a user to Checks
    /// @return `true` if a participant of a poll, `false` otherwise
    function hasMember(address _user) public view returns (bool) {
        return memberOptions[_user] != 0;
    }

    /// @notice Gets vote limit for a poll.
    /// @dev Actually shows the value from associated VotingManager
    /// @return vote limit value
    function getVoteLimit() public view returns (uint) {
        return VotingManagerInterface(lookupManager("VotingManager")).getVoteLimit();
    }

    /// @notice Gets full details of a poll including a number of options
    /// @dev delegatecall only
    /// @return {
    ///   "_owner": "owner",
    ///   "_detailsIpfsHash": "details ipfs hash",
    ///   "_votelimit": "vote limit",
    ///   "_deadline": "deadline time",
    ///   "_status": 'is valid' status,
    ///   "_active": "is activated",
    ///   "_creation": "creation time",
    ///   "_optionsCount": "list of options"
    /// }
    function getDetails() public view returns (
        address _owner,
        bytes32 _detailsIpfsHash,
        uint _votelimit,
        uint _deadline,
        bool _status,
        bool _active,
        uint _creation,
        uint _optionsCount
    ) {
        State _state = state;

        _owner = contractOwner;
        _detailsIpfsHash = detailsIpfsHash;
        _votelimit = votelimit;
        _deadline = deadline;
        _status = _state != State.Finished;
        _active = _state == State.Active;
        _creation = creation;
        _optionsCount = optionsCount;
    }

    /// @notice Gets intermediate retults of a poll by providing options and their balances.
    /// @dev delegatecall only
    /// @return {
    ///   "_options": "poll's options indices",
    ///   "_balances": "associated balances for options"
    /// }
    function getVotesBalances() public view returns (uint8[] _options, uint[] _balances) {
        _options = new uint8[](optionsCount);
        _balances = new uint[](_options.length);

        for (uint8 _idx = 0; _idx < _options.length; ++_idx) {
            _options[_idx] = _idx + 1;
            _balances[_idx] = optionsBalance[_options[_idx]];
        }
    }

    /// @notice Initializes internal variables. Poll by default is not active so to start voting first activate a poll.
    ///
    /// @dev Could be invoked only once. delegatecall only
    ///
    /// @param _optionsCount number of options in a poll
    /// @param _detailsIpfsHash ipfs hash for poll's details info
    /// @param _votelimit votelimit. Should be less than votelimit that is defined on a backend
    /// @param _deadline time to end voting
    ///
    /// @return result code of an operation
    function init(uint _optionsCount, bytes32 _detailsIpfsHash, uint _votelimit, uint _deadline) onlyContractOwner public returns (uint) {
        require(_optionsCount >= 2 && _optionsCount <= OPTIONS_POLLS_MAX);
        require(_detailsIpfsHash != bytes32(0));
        require(_votelimit <= getVoteLimit());
        require(_deadline > now);

        if (creation != 0) {
            return _emitError(ERROR_POLL_BACKEND_INVALID_INVOCATION);
        }

        optionsCount = _optionsCount;
        detailsIpfsHash = _detailsIpfsHash;
        votelimit = _votelimit;
        deadline = _deadline;
        creation = now;

        return OK;
    }

    /// @notice Performs a vote of caller with provided choice. When a required balance for an option will reach
    /// votelimit value then poll automatically ends.
    ///
    /// @dev delegatecall only. Should be called by only those contracts that have balance in TimeHolder.
    /// @param _choice picked option value by user. Should be between 1 and number of options in a poll
    ///
    /// @return _resultCode result code of an operation. Returns ERROR_POLL_BACKEND_NO_SHARES if
    /// a balance in TimeHolder for the user is equal to zero.
    function vote(uint8 _choice) public returns (uint _resultCode) {
        require(_choice > 0 && _choice <= optionsCount);

        if (memberOptions[msg.sender] != 0) {
            return _emitError(ERROR_POLL_BACKEND_ALREADY_VOTED);
        }

        if (!active()) {
            return _emitError(ERROR_POLL_BACKEND_INVALID_STATE);
        }

        address timeHolder = lookupManager("TimeHolder");
        uint balance = TimeHolderInterface(timeHolder).depositBalance(msg.sender);

        if (balance == 0) {
            return _emitError(ERROR_POLL_BACKEND_NO_SHARES);
        }

        uint optionsValue = optionsBalance[_choice].add(balance);
        optionsBalance[_choice] = optionsValue;
        memberVotes[msg.sender] = balance;
        memberOptions[msg.sender] = _choice;

        getPollListener().onVote(address(this), _choice);
        getEventsHistory().emitPollVoted(_choice);

        if (_isReadyToEndPoll(optionsValue)) {
            _endPoll();
        }

        return OK;
    }

    /// @notice Activates poll so users could vote and no more changes can be made.
    /// @dev delegatecall only. Multisignature required
    ///
    /// @return _resultCode result code of an operation.
    function activatePoll() public returns (uint _resultCode) {
        if (state != State.Prepare || creation == 0) {
            return _emitError(ERROR_POLL_BACKEND_INVALID_STATE);
        }

        _resultCode = multisig();
        if (_resultCode != OK) {
            return _checkAndEmitError(_resultCode);
        }

        state = State.Active;

        getPollListener().onActivatePoll();
        getEventsHistory().emitPollActivated();
        return OK;
    }

    /// @notice Ends poll so after that users couldn't vote anymore.
    /// @dev delegatecall only. Multisignature required
    /// @return _resultCode result code of an operation.
    function endPoll() public returns (uint _resultCode) {
        if (!active()) {
            return _emitError(ERROR_POLL_BACKEND_INVALID_STATE);
        }

        _resultCode = multisig();
        if (OK != _resultCode) {
            return _checkAndEmitError(_resultCode);
        }

        return _endPoll();
    }

    /// @notice Erases poll from records. Should be called before activation or after poll completion.
    /// Couldn't be invoked in the middle of voting.
    ///
    /// @dev delegatecall only. Authorized contracts only.
    ///
    /// @return _resultCode result code of an operation.
    function killPoll() public onlyAuthorized {
        if (active()) {
            revert();
        }

        getPollListener().onRemovePoll();

        selfdestruct(contractOwner);
    }

    /** ListenerInterface interface */

    /// @notice Implements deposit method and receives calls from TimeHolder. Updates poll according to changes
    /// made with balance and adds value to a member chosen option.
    /// In case if were deposited enough amount to end a poll it will be ended automatically. Make sence only
    /// for active poll
    /// @dev initialized poll only. VotingManager only
    ///
    /// @param _address address for which changes are made
    /// @param _amount a value of change
    /// @param _total total amount of tokens on _address's balance
    ///
    /// @return result code of an operation
    function tokenDeposit(address, address _address, uint _amount, uint _total) onlyVotingManager public returns (uint) {
        if (!hasMember(_address)) return UNAUTHORIZED;

        if (active()) {
            uint8 _choice = memberOptions[_address];
            uint _value = optionsBalance[_choice];
            _value = _value.add(_amount);
            memberVotes[_address] = _total;
            optionsBalance[_choice] = _value;
        }

        if (_isReadyToEndPoll(_value)) {
            _endPoll();
        }

        return OK;
    }

    /// @notice Implements withdrawn method and receives calls from TimeHolder. Updates poll according to changes
    /// made with balance and removes value from a member's chosen option.
    /// In case if _total value is equal to `0` then _address has no more rights to vote and his choice is reset.
    ///
    /// @dev initialized poll only. VotingManager only
    ///
    /// @param _address address for which changes are made
    /// @param _amount a value of change
    /// @param _total total amount of tokens on _address's balance
    ///
    /// @return result code of an operation
    function tokenWithdrawn(address, address _address, uint _amount, uint _total) onlyVotingManager public returns (uint) {
        if (!hasMember(_address)) return UNAUTHORIZED;

        if (active()) {
            uint8 _choice = memberOptions[_address];
            uint _value = optionsBalance[_choice];
            _value = _value.sub(_amount);
            memberVotes[_address] = _total;
            optionsBalance[_choice] = _value;

            if (_total == 0) {
                delete memberOptions[_address];
            }
        }

        return OK;
    }

    /// @notice Makes search in contractsManager for registered contract by some identifier
    /// @param _identifier string identifier of a manager
    ///
    /// @return manager address of a manager, 0x0 if nothing was found
    function lookupManager(bytes32 _identifier) public view returns (address manager) {
        manager = ContractsManagerInterface(contractsManager).getContractAddressByType(_identifier);
        assert(manager != 0x0);
    }

    /// @dev Don't allow to receive any Ether
    function () public { // TODO:
        revert();
    }

    /** PRIVATE section */

    function _isReadyToEndPoll(uint _value) private view returns (bool) {
        uint _voteLimitNumber = votelimit;
        return _value >= _voteLimitNumber && (_voteLimitNumber > 0 || deadline <= now);
    }

    function _endPoll() private returns (uint _resultCode) {
        if (!active()) {
            return _emitError(ERROR_POLL_BACKEND_INVALID_STATE);
        }

        state = State.Finished;

        getPollListener().onEndPoll();
        getEventsHistory().emitPollEnded();
        return OK;
    }

    /** INTERNAL: Events emitting */

    function _checkAndEmitError(uint _error) internal returns (uint) {
        if (_error != OK && _error != MULTISIG_ADDED) {
            return _emitError(_error);
        }

        return _error;
    }

    function _emitError(uint _error) internal returns (uint) {
        getEventsHistory().emitError(_error);
        return _error;
    }
}
