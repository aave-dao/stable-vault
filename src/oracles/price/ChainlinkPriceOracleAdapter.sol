// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

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

    /// @dev Added to the heartbeat to account for potential publishing delays during periods of network congestion.
    uint256 constant HEARTBEAT_BUFFER_SECONDS = 90;

    address immutable ASSET;
    address immutable DATA_FEED;
    uint256 immutable DECIMALS;
    uint256 immutable HEARTBEAT;

    constructor(address asset, address dataFeed, uint256 heartbeat) {
        ASSET = asset;
        DATA_FEED = dataFeed;
        DECIMALS = AggregatorV3Interface(dataFeed).decimals();
        HEARTBEAT = heartbeat;
    }

    /// @inheritdoc IPriceOracleAdapter
    function getPrice(address asset) external view override returns (IPriceOracleAdapter.OracleResponse memory) {
        require(asset == ASSET, Errors.InvalidAsset(asset));
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(DATA_FEED).latestRoundData();
        uint256 priceRay = _convertDecimalsToRay(price);
        bool isStale = false;
        if (updatedAt < block.timestamp && block.timestamp - updatedAt >= HEARTBEAT + HEARTBEAT_BUFFER_SECONDS) {
            isStale = true;
        }
        return IPriceOracleAdapter.OracleResponse(priceRay, isStale);
    }

    function _convertDecimalsToRay(int256 price) internal view returns (uint256) {
        // Casting to 'uint256' is safe because we checked that price > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(price).convertDecimals(DECIMALS, Constants.RAY_DECIMALS);
    }
}
