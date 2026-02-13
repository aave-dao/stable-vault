// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";

// solhint-disable-next-line interface-starts-with-i
interface IBundleBaseAggregator {
    function latestBundle() external view returns (bytes memory bundle);
    
    function bundleDecimals() external view returns (uint8[] memory);

    function latestBundleTimestamp() external view returns (uint256);
}

/// @title ChainlinkChainBalanceOracleAdapter
/// @author Aave Labs
/// @notice Adapter for fetching a chain aggregated balance value from the Chainlink Aggregator.
/// @dev Queries the bundle aggregator proxy for the latest bundle containing data read from
/// IEarningChainStateProvider::getState().
contract ChainlinkChainBalanceOracleAdapter is IChainBalanceOracleAdapter {
    using AssetLib for uint256;

    /// @notice The version of the IEarningChainStateProvider struct.
    uint256 constant EARNING_CHAIN_STATE_VERSION = 1;
    /// @dev Added to the heartbeat to account for potential publishing delays during periods of network congestion.
    uint256 constant PUBLISH_BUFFER_SECONDS = 90;

    uint256 immutable CHAIN_ID;
    address immutable BUNDLE_AGGREGATOR_PROXY;
    uint256 immutable HEARTBEAT;

    constructor(uint256 chainId, address bundleAggregatorProxy, uint256 heartbeat) {
        CHAIN_ID = chainId;
        BUNDLE_AGGREGATOR_PROXY = bundleAggregatorProxy;
        HEARTBEAT = heartbeat;
    }

    /// @inheritdoc IChainBalanceOracleAdapter
    function getChainBalance(uint256 chainId) external view override returns (IChainBalanceOracle.ChainBalance memory) {
        require(chainId == CHAIN_ID, InvalidChainId(chainId));

        // Check bundle is not stale.
        bool isStale = false;
        uint256 bundleTimestamp = IBundleBaseAggregator(BUNDLE_AGGREGATOR_PROXY).latestBundleTimestamp();
        if (
            bundleTimestamp < block.timestamp && block.timestamp - bundleTimestamp >= HEARTBEAT + PUBLISH_BUFFER_SECONDS
        ) {
            isStale = true;
        }

        // Get balance snapshot from bundle.
        bytes memory bundle = IBundleBaseAggregator(BUNDLE_AGGREGATOR_PROXY).latestBundle();
        IEarningChainStateProvider.State memory state = abi.decode(bundle, (IEarningChainStateProvider.State));
        require(
            state.version == EARNING_CHAIN_STATE_VERSION,
            InvalidEarningChainStateVersion(EARNING_CHAIN_STATE_VERSION, state.version)
        );
        IEarningChainStateProvider.BalanceSnapshot memory balanceSnapshot =
            abi.decode(state.data, (IEarningChainStateProvider.BalanceSnapshot));
        require(balanceSnapshot.chainId == CHAIN_ID, InvalidSnapshotChainId(CHAIN_ID, balanceSnapshot.chainId));

        return IChainBalanceOracle.ChainBalance({
            balanceRay: balanceSnapshot.balanceRay,
            lastUpdateTimestamp: bundleTimestamp,
            sourceChainTimestamp: balanceSnapshot.timestamp,
            sourceChainBlockNumber: balanceSnapshot.blockNumber,
            isStale: isStale
        });
    }
}
