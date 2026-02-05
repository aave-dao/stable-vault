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
    event ChainBalanceAdapterSet(uint256 indexed chainId, address indexed newAdapter, address indexed previousAdapter);

    /// @notice Queries an oracle feed for data representing the aggregate price-adjusted balance of asset from a given
    /// Earning Chain.
    /// @param chainId Earning chain id query data for.
    /// @return uint256 representing the aggregated balance of tokens on the Earning Chain adjusted by their respective
    /// price, normalized to RAY before aggregation.
    function getChainBalance(uint256 chainId) external view returns (uint256);
}
