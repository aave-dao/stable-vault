// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IRescuableAssetToken
/// @author Aave Labs
/// @notice Interface for contracts that can rescue tokens.
interface IRescuableAssetToken {
    /// @notice Rescue tokens stuck on the contract.
    /// @param asset Address of the asset to rescue.
    /// @param amount Amount of the asset to rescue.
    function rescueTokens(address asset, uint256 amount) external;
}
