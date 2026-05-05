// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ISurplusClaimPolicy
/// @author Aave Labs
/// @notice Interface for the contract enforcing conditions on `StableVault.claimSurplusInterest(...)`.
interface ISurplusClaimPolicy {
    /// @notice Emitted when the surplus-claim policy is applied.
    event SurplusClaimPolicyApplied(address indexed caller, address indexed treasury, uint256 numAssets);

    /// @notice Core parameters for a surplus claim.
    /// @param caller `msg.sender` of `StableVault.claimSurplusInterest`.
    /// @param treasury Configured treasury address that will receive the claim.
    /// @param assets Assets being claimed (in the asset's native decimals via `amounts`).
    /// @param amounts Amount of each asset being claimed.
    struct SurplusClaimRequest {
        address caller;
        address treasury;
        address[] assets;
        uint256[] amounts;
    }

    /// @notice Applies the surplus-claim policy.
    /// @param request The surplus-claim request parameters.
    /// @return allowed `true` iff the claim is permitted by the policy.
    function applySurplusClaimPolicy(SurplusClaimRequest calldata request) external returns (bool allowed);

    /// @notice Previews the surplus-claim policy result without modifying state.
    /// @param request The surplus-claim request parameters.
    /// @return allowed `true` iff the claim would be permitted at the current state.
    function previewSurplusClaimPolicy(SurplusClaimRequest calldata request) external view returns (bool allowed);
}
