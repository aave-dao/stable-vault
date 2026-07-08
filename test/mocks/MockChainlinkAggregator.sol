// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

contract MockChainlinkAggregator {
    uint8 internal _decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, block.timestamp, _updatedAt, 1);
    }

    function setAnswer(int256 answer, uint256 updatedAt) external {
        _answer = answer;
        _updatedAt = updatedAt;
    }
}
