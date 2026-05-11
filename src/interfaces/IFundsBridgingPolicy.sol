// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IFundsBridgingPolicy
/// @author Aave Labs
/// @notice Interface for the contract enforcing conditions on outbound funds-bearing bridge messages.
/// @dev Applied only on send-side entry points (e.g. `FundsHandler.pushFundsToChain`,
/// `EarningChainGateway.pushFundsToAccountingChain`).
interface IFundsBridgingPolicy {
    /// @notice Emitted when the bridge-funds policy is applied.
    event FundsBridgingPolicyApplied(
        address indexed caller,
        address bridgeAdapter,
        uint256 indexed destChainId,
        address indexed asset,
        uint256 amount
    );

    /// @notice Parameters for the funds-bearing dispatch path.
    /// @param caller `msg.sender` at the entry point (manager for `pushFundsToChain` /
    /// `pushFundsToAccountingChain`).
    /// @param bridgeAdapter Bridge adapter selected for this dispatch.
    /// @param destChainId Destination chain id.
    /// @param asset The asset being bridged.
    /// @param amount Amount of `asset` being bridged (in the asset's native decimals).
    struct FundsBridgingIntent {
        address caller;
        address bridgeAdapter;
        uint256 destChainId;
        address asset;
        uint256 amount;
    }

    /// @notice Applies the bridge policy for funds-bearing messages. Reverts if the dispatch does not comply with the
    /// policy restrictions.
    /// @param fundsBridging The bridge-funds intent.
    function applyFundsBridgingPolicy(FundsBridgingIntent calldata fundsBridging) external;

    /// @notice Previews the bridge-funds policy result without modifying state.
    /// @param fundsBridging The bridge-funds intent.
    /// @return allowed `true` iff the dispatch would be permitted at the current state.
    function previewFundsBridgingPolicy(FundsBridgingIntent calldata fundsBridging) external view returns (bool allowed);
}
