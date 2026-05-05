// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ITransferPolicy
/// @author Aave Labs
/// @notice Interface for the contract enforcing conditions during StableVault position transfers between users.
interface ITransferPolicy {
    /// @notice Emitted when the transfer policy is applied.
    event TransferPolicyApplied(address indexed from, address indexed to, uint256 amountRay);

    /// @notice Core parameters for a transfer.
    /// @dev `amountRay` is the full position value for `transferAll()`.
    /// @param from The sender of the position value.
    /// @param to The recipient of the position value.
    /// @param amountRay Amount being transferred (RAY).
    /// @param extraData Additional data for the transfer policy.
    struct TransferRequest {
        address from;
        address to;
        uint256 amountRay;
        bytes extraData;
    }

    /// @notice Applies the transfer policy.
    /// @param request The transfer request parameters.
    /// @return allowed `true` iff the transfer is permitted by the policy.
    function applyTransferPolicy(TransferRequest calldata request) external returns (bool allowed);

    /// @notice Previews the transfer policy result without modifying state.
    /// @param request The transfer request parameters.
    /// @return allowed `true` iff the transfer would be permitted at the current state.
    function previewTransferPolicy(TransferRequest calldata request) external view returns (bool allowed);
}
