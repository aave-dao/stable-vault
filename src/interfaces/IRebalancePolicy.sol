// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAllocator} from "src/interfaces/IAllocator.sol";

/// @title IRebalancePolicy
/// @author Aave Labs
/// @notice Interface for the contract enforcing conditions on `Allocator.rebalance(...)` calls.
interface IRebalancePolicy {
    /// @notice Emitted when the rebalance policy is applied.
    event RebalancePolicyApplied(address indexed caller, uint256 numRebalances);

    /// @notice Core parameters for a rebalance.
    /// @param caller `msg.sender` of `Allocator.rebalance`.
    /// @param params The native rebalance parameters (deallocations / swaps / allocations).
    struct RebalanceRequest {
        address caller;
        IAllocator.RebalanceParams[] params;
    }

    /// @notice Applies the rebalance policy.
    /// @param request The rebalance request parameters.
    /// @return allowed `true` iff the rebalance is permitted by the policy.
    function applyRebalancePolicy(RebalanceRequest calldata request) external returns (bool allowed);

    /// @notice Previews the rebalance policy result without modifying state.
    /// @param request The rebalance request parameters.
    /// @return allowed `true` iff the rebalance would be permitted at the current state.
    function previewRebalancePolicy(RebalanceRequest calldata request) external view returns (bool allowed);
}
