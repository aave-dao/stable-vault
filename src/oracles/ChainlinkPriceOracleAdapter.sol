// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IPriceOracleAdapter} from "../interfaces/IPriceOracleAdapter.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {Constants} from "../types/Constants.sol";

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

/// @title ChainlinkPriceOracleAdapter
/// @author Aave Labs
/// @notice Adapter for fetching a single asset's price data from the Chainlink Aggregator.
contract ChainlinkPriceOracleAdapter is IPriceOracleAdapter {
    using AssetLib for uint256;

    address immutable DATA_FEED;
    uint256 immutable DECIMALS;
    uint256 immutable HEARTBEAT;

    constructor(address dataFeed, uint256 heartbeat) {
        DATA_FEED = dataFeed;
        DECIMALS = AggregatorV3Interface(dataFeed).decimals();
        HEARTBEAT = heartbeat;
    }

    function getPrice(
        address /* asset */
    )
        external
        view
        override
        returns (IPriceOracleAdapter.OracleResponse memory)
    {
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(DATA_FEED).latestRoundData();
        require(price > 0, IPriceOracleAdapter.InvalidPrice());
        uint256 priceRay = uint256(price).convertDecimals(DECIMALS, Constants.RAY_DECIMALS);
        bool isStale = false;
        if (updatedAt < block.timestamp && block.timestamp - updatedAt >= HEARTBEAT) {
            isStale = true;
        }
        return IPriceOracleAdapter.OracleResponse(priceRay, isStale);
    }
}
