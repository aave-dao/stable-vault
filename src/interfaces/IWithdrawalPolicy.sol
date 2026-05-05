// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IWithdrawalPolicy
/// @author Aave Labs
/// @notice Interface of the contract enforcing conditions across the withdrawal lifecycle.
/// @dev Withdrawal-request limits must not apply to the user's principal portion.
interface IWithdrawalPolicy {
    /// @notice Emitted when a nonce is marked as used, either by a successful appliance of the withdrawal policy or by
    /// a nonce invalidation.
    event NonceUsed(address indexed signer, uint256 indexed nonce);

    /// @notice Emitted when an address is added or removed from the set of whitelisted signers.
    event SignerSet(address indexed signer, bool indexed whitelistAsSigner);

    /// @notice Emitted when the default fee in basis points is set.
    event DefaultFeeBpsSet(uint16 defaultFeeBps);

    /// @notice Emitted when the asset fee in basis points is set.
    event AssetFeeBpsSet(address indexed asset, uint16 assetFeeBps, bool isSet);

    /// @notice Emitted when the withdrawal policy is applied and a fee is charged.
    event WithdrawalPolicyApplied(address indexed user, address assetOut, uint256 iouAmountRay, uint256 amountOutRay);

    /// @notice Emitted when the withdrawal-request policy is applied.
    event WithdrawalRequestPolicyApplied(address indexed caller, address indexed user, uint256 requestedAmountInRay);

    /// @notice Thrown when a recovered signer is not a whitelisted signer.
    /// @custom:selector 0x8baa579f
    error InvalidSignature();

    /// @notice Thrown when a signature nonce has already been consumed.
    /// @custom:selector 0x1fb09b80
    error NonceAlreadyUsed();

    /// @notice Thrown when the signature deadline has passed.
    /// @custom:selector 0x1ab7da6b
    error DeadlineExpired();

    /// @notice Core parameters for the IOU to asset exchange stage.
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

    /// @notice Applies the withdrawal policy and returns the final amount the user receives.
    /// @dev May have side effects (e.g., consuming nonces). Reverts if policy is violated.
    /// @param request The withdrawal request parameters.
    /// @return The amount of assets the user will receive (in RAY), after the withdrawal policy is applied.
    function applyWithdrawalPolicy(WithdrawalRequest calldata request) external returns (uint256);

    /// @notice Previews the withdrawal policy result without modifying state.
    /// @dev Validates everything (asset, signature, deadline, nonce) but doesn't consume the nonce.
    /// @param request The withdrawal request parameters.
    /// @return The amount of assets the user would receive (in RAY), after the withdrawal policy is applied.
    function previewWithdrawalPolicy(WithdrawalRequest calldata request) external view returns (uint256);

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
