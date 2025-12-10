// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IWithdrawalPolicy
/// @author Aave Labs
/// @notice Interface for withdrawal policy contracts that determine the final withdrawal amount.
interface IWithdrawalPolicy {
    /// @notice Core parameters for a withdrawal request.
    /// @param user Address of the user withdrawing.
    /// @param assetOut Address of the asset to receive.
    /// @param iouAmountRay Amount of IOU tokens being redeemed (in RAY).
    /// @param data Implementation-specific data (e.g., signed fee discounts).
    struct WithdrawalRequest {
        address user;
        address assetOut;
        uint256 iouAmountRay;
        bytes data;
    }

    /// @notice Applies the withdrawal policy and returns the final amount the user receives.
    /// @dev May have side effects (e.g., consuming nonces). Reverts if policy is violated.
    /// @param request The withdrawal request parameters.
    /// @return The amount of assets the user will receive (in RAY), after all fees and adjustments.
    function applyWithdrawalPolicy(WithdrawalRequest calldata request) external returns (uint256);

    /// @notice Previews the withdrawal policy result without modifying state.
    /// @dev Validates everything (asset, signature, deadline, nonce) but doesn't consume the nonce.
    /// @param request The withdrawal request parameters.
    /// @return The amount of assets the user would receive (in RAY), after all fees and adjustments.
    function previewWithdrawalPolicy(WithdrawalRequest calldata request) external view returns (uint256);
}
