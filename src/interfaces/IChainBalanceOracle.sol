// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IChainBalanceOracle
/// @author Aave Labs
/// @notice Interface for chain balance oracle functionality required on the Accounting Chain.
interface IChainBalanceOracle {
    /// @notice The representation of the response from the oracle.
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
    /// @dev Must revert when the chain ID is not supported by this oracle, so callers can rely on a successful return
    /// meaning the chain is supported. A supported chain that cannot produce fresh data does not revert here; it
    /// returns isStale = true.
    /// @param chainId Earning chain ID to query data for.
    /// @return ChainBalance response from the oracle.
    function getChainBalance(uint256 chainId) external view returns (ChainBalance memory);
}
