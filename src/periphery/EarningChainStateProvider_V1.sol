// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title EarningChainStateProvider_V1
/// @author Aave Labs
/// @notice Version 1 of the Earning Chain State Provider.
/// @dev This contract is used to define the version and the Balance Snapshot struct.
contract EarningChainStateProvider_V1 {
    uint256 public constant VERSION = 1;

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
