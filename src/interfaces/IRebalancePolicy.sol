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
    /// @param policyData Additional data that the rebalance policy might need to operate.
    struct RebalanceIntent {
        address caller;
        IAllocator.RebalanceParams[] params;
        bytes policyData;
    }

    /// @notice Applies the rebalance policy. Reverts if the rebalance does not comply with the policy restrictions.
    /// @param rebalance The rebalance intent.
    function applyRebalancePolicy(RebalanceIntent calldata rebalance) external;

    /// @notice Previews the rebalance policy result without modifying state.
    /// @param rebalance The rebalance intent.
    /// @return allowed `true` iff the rebalance would be permitted at the current state.
    function previewRebalancePolicy(RebalanceIntent calldata rebalance) external view returns (bool allowed);
}
