// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";

/// @title PolicyRegistry
/// @author Aave Labs
/// @notice Keeps a registry of policy contract addresses by ID.
contract PolicyRegistry is AccessManaged, IPolicyRegistry {
    mapping(bytes32 policyId => address policyAddress) internal _policies;

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    constructor(address accessManager) AccessManaged(accessManager) {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
    }

    /// @inheritdoc IPolicyRegistry
    function setPolicy(bytes32 policyId, address policyAddress) external override restricted {
        address oldPolicyAddress = _policies[policyId];
        _policies[policyId] = policyAddress;
        emit PolicySet(policyId, oldPolicyAddress, policyAddress);
    }

    /// @inheritdoc IPolicyRegistry
    function getPolicy(bytes32 policyId) external view override returns (address) {
        return _policies[policyId];
    }
}
