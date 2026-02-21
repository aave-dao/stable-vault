// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {L2ChainlinkOracleAdapter} from "src/oracles/common/L2ChainlinkOracleAdapter.sol";
import {ChainlinkPriceOracleAdapter} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";

/// @title ChainlinkL2PriceOracleAdapter
/// @author Aave Labs
/// @notice Extends ChainlinkPriceOracleAdapter with an L2 sequencer uptime feed check.
contract ChainlinkL2PriceOracleAdapter is L2ChainlinkOracleAdapter, ChainlinkPriceOracleAdapter {
    /// @param asset The asset address this adapter serves.
    /// @param dataFeed The Chainlink price data feed address.
    /// @param heartbeat The expected heartbeat interval for the price feed.
    /// @param sequencerUptimeFeed The Chainlink L2 Sequencer Uptime Feed address.
    constructor(address asset, address dataFeed, uint256 heartbeat, address sequencerUptimeFeed)
        L2ChainlinkOracleAdapter(sequencerUptimeFeed)
        ChainlinkPriceOracleAdapter(asset, dataFeed, heartbeat)
    {}

    /// @inheritdoc IPriceOracleAdapter
    function getPrice(address asset) external view override returns (IPriceOracleAdapter.OracleResponse memory) {
        IPriceOracleAdapter.OracleResponse memory response = _getPrice(asset);
        if (!_isFeedHealthy()) {
            response.isStale = true;
        }
        return response;
    }
}
