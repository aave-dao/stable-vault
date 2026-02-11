// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

interface IEarningChainState {
    /// @notice The representation of the Earning Chain State.
    /// @param version The version of the Earning Chain State struct.
    /// @param data The encoded data of the Earning Chain State to be decoded on the Accounting Chain based on the
    /// version.
    struct State {
        uint256 version;
        bytes data;
    }

    /// @notice The representation of the Balance Snapshot.
    /// @param balanceRay The balance of the Earning Chain in RAY.
    /// @param timestamp The timestamp of the Balance Snapshot.
    /// @param blockNumber The block number of the Balance Snapshot.
    struct BalanceSnapshot {
        uint256 balanceRay;
        uint256 timestamp;
        uint256 blockNumber;
    }

    /// @notice Gets the current state of the Earning Chain.
    /// @return state The encoded State struct to be decoded on the Accounting Chain based on the version.
    function getState() external view returns (bytes memory);
}
