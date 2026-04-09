// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IChainBalanceOracle
/// @author Aave Labs
/// @notice Interface for chain balance oracle functionality required on the Accounting Chain.
interface IChainBalanceOracle {
    /// @notice Thrown when the adapter for a chain is not found.
    /// @custom:selector 0x3f3e70bf
    error ChainBalanceOracleAdapterNotFound(uint256 chainId);

    /// @notice Emitted when an adapter is set for a chain.
    event ChainBalanceAdapterSet(uint256 indexed chainId, address indexed previousAdapter, address indexed newAdapter);

    /// @notice The representation of the response from the oracle adapter.
    /// @param balanceRay The aggregated balance on a given chain in ray units.
    /// @param lastUpdateTimestamp The timestamp of the last update published to the destination chain.
    /// @param sourceChainTimestamp The timestamp at which the source Earning Chain data was read.
    /// @param sourceChainBlockNumber The block number at which the source Earning Chain data was read.
    /// @param isStale Whether the balance is considered stale based on data source spec.
    struct ChainBalance {
        uint256 balanceRay;
        uint256 lastUpdateTimestamp;
        uint256 sourceChainTimestamp;
        uint256 sourceChainBlockNumber;
        bool isStale;
    }

    /// @notice Queries an oracle feed for data representing the aggregate price-adjusted balance of an asset from a
    /// given Earning Chain.
    /// @param chainId Earning chain id to query data for.
    /// @return ChainBalance response from the oracle adapter.
    function getChainBalance(uint256 chainId) external view returns (ChainBalance memory);
}
