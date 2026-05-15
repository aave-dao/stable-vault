// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IDepositPolicy
/// @author Aave Labs
/// @notice Interface for the contract enforcing conditions during deposits into the StableVault.
interface IDepositPolicy {
    /// @notice Emitted when the deposit policy is applied.
    event DepositPolicyApplied(address indexed caller, address indexed user, address indexed asset, uint256 amount);

    /// @notice Core parameters for a deposit.
    /// @param caller `msg.sender` of `StableVault.deposit` (may differ from `user`, e.g. relayer/custodian flows).
    /// @param user The position beneficiary.
    /// @param asset The asset being deposited.
    /// @param amount The amount of `asset` being deposited (in the asset's native decimals).
    /// @param policyData Additional data that the deposit policy might need to operate.
    struct DepositIntent {
        address caller;
        address user;
        address asset;
        uint256 amount;
        bytes policyData;
    }

    /// @notice Applies the deposit policy. Reverts if the deposit does not comply with the policy restrictions.
    /// @param deposit The deposit intent.
    function applyDepositPolicy(DepositIntent calldata deposit) external;

    /// @notice Previews the deposit policy result without modifying state.
    /// @param deposit The deposit intent.
    /// @return allowed `true` iff the deposit would be permitted at the current state.
    function previewDepositPolicy(DepositIntent calldata deposit) external view returns (bool allowed);
}
