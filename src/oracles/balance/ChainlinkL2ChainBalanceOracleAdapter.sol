// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {ChainlinkChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkChainBalanceOracleAdapter.sol";
import {L2ChainlinkOracleAdapter} from "src/oracles/common/L2ChainlinkOracleAdapter.sol";

/// @title ChainlinkL2ChainBalanceOracleAdapter
/// @author Aave Labs
/// @notice Extends ChainlinkChainBalanceOracleAdapter with an L2 sequencer uptime feed check.
contract ChainlinkL2ChainBalanceOracleAdapter is L2ChainlinkOracleAdapter, ChainlinkChainBalanceOracleAdapter {
    /// @dev Constructor.
    /// @param earningChainId The earning chain id this adapter serves.
    /// @param bundleAggregatorProxy The Chainlink bundle aggregator proxy address.
    /// @param heartbeat The expected heartbeat interval for the bundle feed.
    /// @param sequencerUptimeFeed The Chainlink L2 Sequencer Uptime Feed address.
    constructor(uint256 earningChainId, address bundleAggregatorProxy, uint256 heartbeat, address sequencerUptimeFeed)
        ChainlinkChainBalanceOracleAdapter(earningChainId, bundleAggregatorProxy, heartbeat)
        L2ChainlinkOracleAdapter(sequencerUptimeFeed)
    {}

    /// @inheritdoc IChainBalanceOracleAdapter
    function getChainBalance(uint256 chainId) external view override returns (IChainBalanceOracle.ChainBalance memory) {
        IChainBalanceOracle.ChainBalance memory response = _getChainBalance(chainId);
        if (!_isFeedHealthy()) {
            response.isStale = true;
        }
        return response;
    }
}
