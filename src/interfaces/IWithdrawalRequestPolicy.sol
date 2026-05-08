// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IWithdrawalRequestPolicy
/// @author Aave Labs
/// @notice Interface for the contract enforcing conditions when a user requests a withdrawal (i.e. on
/// `StableVault.requestWithdrawal`).
/// @dev Withdrawal-request limits must not apply to the user's principal portion.
interface IWithdrawalRequestPolicy {
    /// @notice Emitted when the withdrawal-request policy is applied.
    event WithdrawalRequestPolicyApplied(address indexed caller, address indexed user, uint256 requestedAmountInRay);

    /// @notice Core parameters for the withdrawal-request stage (used by `requestWithdrawal`).
    /// @param caller `msg.sender` of `StableVault.requestWithdrawal` (must equal `user`).
    /// @param user The user requesting the withdrawal.
    /// @param requestedAmountInRay Total amount the user requested (RAY).
    /// @param extraData Additional data for the withdrawal-request policy.
    struct WithdrawalRequestPolicyRequest {
        address caller;
        address user;
        uint256 requestedAmountInRay;
        bytes extraData;
    }

    /// @notice Applies the withdrawal-request policy.
    /// @param request The withdrawal-request parameters.
    /// @return allowed `true` iff the withdrawal request is permitted by the policy.
    function applyWithdrawalRequestPolicy(WithdrawalRequestPolicyRequest calldata request)
        external
        returns (bool allowed);

    /// @notice Previews the withdrawal-request policy result without modifying state.
    /// @param request The withdrawal-request parameters.
    /// @return allowed `true` iff the withdrawal request would be permitted at the current state.
    function previewWithdrawalRequestPolicy(WithdrawalRequestPolicyRequest calldata request)
        external
        view
        returns (bool allowed);
}
