// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IWithdrawalExecutionPolicy
/// @author Aave Labs
/// @notice Interface for the contract enforcing conditions on the IOU-to-asset exchange stage of a withdrawal (i.e.
/// when a user calls `executeWithdrawal` / `exchangeIouTokens`).
interface IWithdrawalExecutionPolicy {
    /// @notice Emitted when the withdrawal policy is applied and a fee is charged.
    event WithdrawalExecutionPolicyApplied(
        address indexed user, address assetOut, uint256 iouAmountRay, uint256 amountOutRay
    );

    /// @notice Core parameters for the IOU to asset exchange stage.
    /// @param user Address of the user withdrawing.
    /// @param assetOut Address of the asset to receive.
    /// @param iouAmountRay Amount of IOU tokens being redeemed (in RAY).
    /// @param data Implementation-specific data (e.g., signed fee discounts).
    struct WithdrawalExecutionIntent {
        address user;
        address assetOut;
        uint256 iouAmountRay;
        bytes data;
    }

    /// @notice Applies the withdrawal policy and returns the final amount the user receives.
    /// @dev May have side effects (e.g., consuming nonces). Reverts if policy is violated.
    /// @param withdrawalExecution The withdrawal-execution intent.
    /// @return The amount of assets the user will receive (in RAY), after the withdrawal policy is applied.
    function applyWithdrawalExecutionPolicy(WithdrawalExecutionIntent calldata withdrawalExecution)
        external
        returns (uint256);

    /// @notice Previews the withdrawal policy result without modifying state.
    /// @dev Validates everything (asset, signature, deadline, nonce) but doesn't consume the nonce.
    /// @param withdrawalExecution The withdrawal-execution intent.
    /// @return The amount of assets the user would receive (in RAY), after the withdrawal policy is applied.
    function previewWithdrawalExecutionPolicy(WithdrawalExecutionIntent calldata withdrawalExecution)
        external
        view
        returns (uint256);
}
