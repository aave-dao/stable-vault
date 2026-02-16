// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @dev Schema version for EarningChainStateSchemaV1, declared at file level so any importer can reference it.
uint256 constant SCHEMA_VERSION = 1;

/// @title EarningChainStateSchemaV1
/// @author Aave Labs
/// @notice Defines the version and data types for Version 1 of the Earning Chain State.
/// @dev Shared between the provider (Earning Chain) and the adapter (Accounting Chain) so that both
/// sides agree on the encoding without duplicating constants or struct definitions.
abstract contract EarningChainStateSchemaV1 {
    /// @notice The representation of the Balance Snapshot.
    /// @param balanceRay The balance of the Earning Chain in RAY.
    /// @param timestamp The timestamp of the Balance Snapshot.
    /// @param blockNumber The block number of the Balance Snapshot.
    /// @param chainId The chain id of the Balance Snapshot.
    struct BalanceSnapshot {
        uint256 balanceRay;
        uint256 timestamp;
        uint256 blockNumber;
        uint256 chainId;
    }
}
