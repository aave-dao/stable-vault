// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IRescuableNative
/// @author Aave Labs
/// @notice Interface for contracts that can rescue native assets.
interface IRescuableNative {
    /// @notice Rescue native assets stuck on the contract.
    /// @param amount Amount of the native asset to rescue.
    function rescueNative(uint256 amount) external;
}
