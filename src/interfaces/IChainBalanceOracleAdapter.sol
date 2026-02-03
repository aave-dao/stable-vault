// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IChainBalanceOracleAdapter
/// @author Aave Labs
/// @notice Interface for the Chain Balance Oracle Adapter contract that fetches chain aggregated balance value from an
/// underlying data source.
interface IChainBalanceOracleAdapter {
    /// @notice Thrown when the balance obtained from the underlying data source is invalid.
    /// @custom:selector 0xc52e3eff
    error InvalidBalance();

    /// @notice Thrown when the chain id is not what was expected.
    /// @custom:selector 0x331003b3
    error InvalidChainId(uint256 chainId);

    /// @notice The representation of the response from the oracle adapter.
    /// @param balanceRay The aggregated balance on a given chain in ray units.
    /// @param lastUpdateTimestamp The timestamp of the last update published to the destination chain.
    /// @param isStale Whether the balance is considered stale based on data source spec.
    struct OracleResponse {
        uint256 balanceRay;
        uint256 lastUpdateTimestamp;
        bool isStale;
    }

    /// @notice Calls a configured data source to fetch the aggregated balance on a given chain.
    /// @param chainId The chain id to get the aggregated balance from the data source.
    /// @return OracleResponse
    function getChainBalance(uint256 chainId) external view returns (OracleResponse memory);
}
