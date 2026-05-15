// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IPolicyRegistry
/// @author Aave Labs
/// @notice Interface for the contract that maps policy IDs to policy contract addresses.
interface IPolicyRegistry {
    /// @notice Emitted when a policy is set for a given ID.
    /// @param policyId The keccak256-hashed identifier of the policy slot.
    /// @param oldPolicyAddress The previous policy address bound to `policyId` (`address(0)` if unset).
    /// @param newPolicyAddress The new policy address bound to `policyId` (`address(0)` clears the slot).
    event PolicySet(bytes32 indexed policyId, address indexed oldPolicyAddress, address indexed newPolicyAddress);

    /// @notice Binds a policy contract address to a policy ID. Setting `policyAddress` to `address(0)` clears the slot.
    /// @param policyId The keccak256-hashed identifier of the policy slot.
    /// @param policyAddress Address of the policy contract to bind.
    function setPolicy(bytes32 policyId, address policyAddress) external;

    /// @notice Returns the policy address bound to `policyId`, or `address(0)` if no policy is set.
    /// @param policyId The keccak256-hashed identifier of the policy slot.
    /// @return policyAddress The bound policy contract address.
    function getPolicy(bytes32 policyId) external view returns (address policyAddress);
}
