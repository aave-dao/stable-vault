// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IChainBalanceOracle
/// @author Aave Labs
/// @notice Interface for chain balance oracle functionality required on the Accounting Chain.
interface IChainBalanceOracle {
    /// @notice Queries an oracle feed for data representing the aggregate price-adjusted balance of asset from a given
    /// Earning Chain.
    /// @param chainId Earning chain id query data for.
    /// @return uint256 representing the aggregated balance of tokens on the Earning Chain adjusted by their respective
    /// price, normalized to RAY before aggregation.
    function getChainBalance(uint256 chainId) external view returns (uint256);
}
