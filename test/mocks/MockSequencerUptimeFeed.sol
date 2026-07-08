// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Mock for the Chainlink L2 Sequencer Uptime Feed.
/// @dev answer: 0 = sequencer is up, 1 = sequencer is down.
/// @dev startedAt: the timestamp when the sequencer last changed status.
contract MockSequencerUptimeFeed {
    int256 internal _answer;
    uint256 internal _startedAt;

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, _startedAt, block.timestamp, 1);
    }

    /// @param answer 0 = sequencer up, 1 = sequencer down.
    /// @param startedAt The timestamp when the sequencer last changed status.
    function setAnswer(int256 answer, uint256 startedAt) external {
        _answer = answer;
        _startedAt = startedAt;
    }
}
