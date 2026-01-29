// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Constants} from "src/types/Constants.sol";

// solhint-disable-next-line interface-starts-with-i
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkChainBalanceOracleAdapter
/// @author Aave Labs
/// @notice Adapter for fetching a chain aggregated balance value from the Chainlink Aggregator.
contract ChainlinkChainBalanceOracleAdapter is IChainBalanceOracleAdapter {
    using AssetLib for uint256;

    address immutable DATA_FEED;
    uint256 immutable DECIMALS;
    uint256 immutable HEARTBEAT;

    constructor(address dataFeed, uint256 heartbeat) {
        DATA_FEED = dataFeed;
        DECIMALS = AggregatorV3Interface(dataFeed).decimals();
        HEARTBEAT = heartbeat;
    }

    function getChainBalance(
        uint256 /* chainId */
    )
        external
        view
        override
        returns (IChainBalanceOracleAdapter.OracleResponse memory)
    {
        (, int256 balance,, uint256 updatedAt,) = AggregatorV3Interface(DATA_FEED).latestRoundData();
        require(balance > 0, IChainBalanceOracleAdapter.InvalidBalance());
        // Casting to 'uint256' is safe because we checked that balance > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 balanceRay = uint256(balance).convertDecimals(DECIMALS, Constants.RAY_DECIMALS);
        bool isStale = false;
        if (updatedAt < block.timestamp && block.timestamp - updatedAt >= HEARTBEAT) {
            isStale = true;
        }
        return IChainBalanceOracleAdapter.OracleResponse(balanceRay, isStale);
    }
}
