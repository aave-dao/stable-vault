// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IChainBalanceOracleAdapter
/// @author Aave Labs
/// @notice Interface for the Chain Balance Oracle Adapter contract that fetches chain aggregated balance value from an
/// underlying data source.
interface IChainBalanceOracleAdapter {
    // TODO: selector and stuff
    error InvalidBalance();

    struct OracleResponse {
        uint256 balanceRay;
        bool isStale;
    }

    function getChainBalance(uint256 chainId) external view returns (OracleResponse memory);
}
