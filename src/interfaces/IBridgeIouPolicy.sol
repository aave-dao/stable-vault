// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IBridgeIouPolicy
/// @author Aave Labs
/// @notice Interface for the contract enforcing conditions on outbound IOU-bridge messages (data-only dispatches).
interface IBridgeIouPolicy {
    /// @notice Emitted when the bridge-iou policy is applied.
    event BridgeIouPolicyApplied(address indexed caller, uint256 indexed destChainId, uint256 iouAmountRay);

    /// @notice Parameters for the data-only IOU-bridge dispatch path.
    /// @param caller `msg.sender` at the entry point.
    /// @param destChainId Destination chain id.
    /// @param recipient The IOU recipient on the destination chain.
    /// @param iouAmountRay Amount of IOUs being bridged (RAY).
    /// @param extraData Additional data for the bridge policy.
    struct BridgeIouRequest {
        address caller;
        uint256 destChainId;
        address recipient;
        uint256 iouAmountRay;
        bytes extraData;
    }

    /// @notice Applies the bridge policy for IOU data-only messages.
    /// @param request The bridge-iou request parameters.
    /// @return allowed `true` iff the dispatch is permitted by the policy.
    function applyBridgeIouPolicy(BridgeIouRequest calldata request) external returns (bool allowed);

    /// @notice Previews the bridge-iou policy result without modifying state.
    /// @param request The bridge-iou request parameters.
    /// @return allowed `true` iff the dispatch would be permitted at the current state.
    function previewBridgeIouPolicy(BridgeIouRequest calldata request) external view returns (bool allowed);
}
