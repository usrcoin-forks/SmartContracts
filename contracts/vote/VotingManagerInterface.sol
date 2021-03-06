pragma solidity ^0.4.11;


/// @title Defines public interface for voting managers.
contract VotingManagerInterface {

    /** Getters */

    /// @notice Gets vote limit that was setup for a manager
    function getVoteLimit() public view returns (uint);

    /// @notice Gets a number of polls registered in a manager
    function getPollsCount() public view returns (uint);

    /// @notice Requests paginated results for a list of polls.
    function getPollsPaginated(uint _startIndex, uint32 _pageSize) public view returns (address[] _votings);

    /// @notice Gets a number of active polls. Could be restricted to some upper bounds.
    function getActivePollsCount() public view returns (uint);

    /// @notice Gets detailed info for a list of provided polls.
    function getPollsDetails(address[] _polls) public view returns (
        address[] _owner,
        bytes32[] _detailsIpfsHash,
        uint[] _votelimit,
        uint[] _deadline,
        bool[] _status,
        bool[] _active,
        uint[] _creation
    );


    /** Actions */

    /// @notice Updates percents of total shares that should be locked (put) in a poll to say that poll is legally completed
    function setVotesPercent(uint _percent) public returns (uint _resultCode);

    /// @notice Creates a new poll and register it in a manager.
    function createPoll(
        uint _optionsCount,
        bytes32 _detailsIpfsHash,
        uint _votelimit,
        uint _deadline
    ) public returns (uint);
}
