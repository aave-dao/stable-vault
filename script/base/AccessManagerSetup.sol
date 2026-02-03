// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {RolesLib} from "script/libraries/RolesLib.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {_toSelectorArray} from "test/helpers/TypeHelpers.sol";

abstract contract AccessManagerSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    //////////////// Admin Profiles ////////////////
    address constant HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE = address(0);
    address constant MED_THRESHOLD_MULTISIG_ADMIN_PROFILE = address(0);

    //////////////// Operational Profiles ////////////////
    address constant WITHDRAWAL_POLICY_MANAGER_PROFILE = address(0);
    address constant BBV_MANAGER_PROFILE = address(0);
    address constant BBV_REBALANCER_PROFILE = address(0);
    address constant BBV_GUARDIAN_PROFILE = address(0);
    address constant ATOKEN_VAULT_REWARD_CLAIMER_PROFILE = address(0);

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupAll(address deployer) internal {
        IAccessManager accessManager = IAccessManager(_accessManager());

        // Setup all profiles by granting roles to them, with their respective execution delays
        _setupProfile__MainAdmin();
        _setupProfile__SecondaryAdmin();
        _setupProfile__WithdrawalPolicyManager();
        _setupProfile__BbvManager();
        _setupProfile__BbvRebalancer();
        _setupProfile__BbvGuardian();

        // Setup role hierarchy by configuring role guardians
        _setupRoleGuardians();

        // Setup role granting delays
        _setupRoleGrantingDelays();

        // Setup the ADMIN_ROLE delay
        accessManager.setTargetAdminDelay(address(accessManager), RolesLib.CRITICAL_DELAY);

        // TODO: Setup the link between target and its allowed role, with
        _setupTarget__Bbv();

        // Revoke deployer's access to ADMIN_ROLE
        accessManager.revokeRole(RolesLib.ADMIN_ROLE, deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _accessManager() internal view virtual returns (address);

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _getProfile__MainAdmin() internal pure virtual returns (address) {
        return HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE;
    }

    function _getProfile__SecondaryAdmin() internal pure virtual returns (address) {
        return MED_THRESHOLD_MULTISIG_ADMIN_PROFILE;
    }

    function _getProfile__WithdrawalPolicyManager() internal pure virtual returns (address) {
        return WITHDRAWAL_POLICY_MANAGER_PROFILE;
    }

    function _getProfile__BbvManager() internal pure virtual returns (address) {
        return BBV_MANAGER_PROFILE;
    }

    function _getProfile__BbvRebalancer() internal pure virtual returns (address) {
        return BBV_REBALANCER_PROFILE;
    }

    function _getProfile__BbvGuardian() internal pure virtual returns (address) {
        return BBV_GUARDIAN_PROFILE;
    }

    function _getProfile__aTokenVaultRewardClaimer() internal pure virtual returns (address) {
        return ATOKEN_VAULT_REWARD_CLAIMER_PROFILE;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__Bbv() internal {
        address bbv;
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](4);

        role = RolesLib.getRole__setUserRate();
        multicallCalldata[0] =
            abi.encodeCall(IAccessManager.setTargetFunctionRole, (bbv, _toSelectorArray(role.selector), role.roleId));

        role = RolesLib.getRole__setSubVaultRate();
        multicallCalldata[1] =
            abi.encodeCall(IAccessManager.setTargetFunctionRole, (bbv, _toSelectorArray(role.selector), role.roleId));

        role = RolesLib.getRole__setDefaultSubVault();
        multicallCalldata[2] =
            abi.encodeCall(IAccessManager.setTargetFunctionRole, (bbv, _toSelectorArray(role.selector), role.roleId));

        role = RolesLib.getRole__claimSurplusInterest();
        multicallCalldata[3] =
            abi.encodeCall(IAccessManager.setTargetFunctionRole, (bbv, _toSelectorArray(role.selector), role.roleId));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupRoleGuardians() internal {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            multicallCalldata[i] =
                abi.encodeCall(IAccessManager.setRoleGuardian, (roles[i].roleId, roles[i].guardianRoleId));
        }
        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupRoleGrantingDelays() internal {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            multicallCalldata[i] = abi.encodeCall(IAccessManager.setGrantDelay, (roles[i].roleId, roles[i].delay));
        }
        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupProfile__MainAdmin() internal {
        address mainAdmin = _getProfile__MainAdmin();

        RolesLib.Role[] memory functionBasedRoles = RolesLib.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](functionBasedRoles.length + 3);

        // Grant ADMIN_ROLE
        multicallCalldata[0] =
            abi.encodeCall(IAccessManager.grantRole, (RolesLib.ADMIN_ROLE, mainAdmin, RolesLib.CRITICAL_DELAY));

        // Grant All Role-Guardian roles
        multicallCalldata[1] =
            abi.encodeCall(IAccessManager.grantRole, (RolesLib.ADMIN_ROLE_GUARDIAN_ROLE, mainAdmin, RolesLib.NO_DELAY));
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.grantRole, (RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE, mainAdmin, RolesLib.NO_DELAY)
        );

        // Grant All Function-Based roles
        for (uint256 i = 0; i < functionBasedRoles.length; i++) {
            multicallCalldata[i + 3] = abi.encodeCall(
                IAccessManager.grantRole, (functionBasedRoles[i].roleId, mainAdmin, functionBasedRoles[i].delay)
            );
        }

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__SecondaryAdmin() internal {
        address secondaryAdmin = _getProfile__SecondaryAdmin();

        RolesLib.Role[] memory functionBasedRoles = RolesLib.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](functionBasedRoles.length + 1);

        // Grant Operation-Role Guardian role
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.grantRole, (RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE, secondaryAdmin, RolesLib.NO_DELAY)
        );

        // Grant All Function-Based roles
        for (uint256 i = 0; i < functionBasedRoles.length; i++) {
            multicallCalldata[i + 1] = abi.encodeCall(
                IAccessManager.grantRole, (functionBasedRoles[i].roleId, secondaryAdmin, functionBasedRoles[i].delay)
            );
        }

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__WithdrawalPolicyManager() internal {
        address withdrawalPolicyManager = _getProfile__WithdrawalPolicyManager();

        bytes[] memory multicallCalldata = new bytes[](2);
        RolesLib.Role memory role;

        role = RolesLib.getRole__setDefaultFeeBps();
        multicallCalldata[0] =
            abi.encodeCall(IAccessManager.grantRole, (role.roleId, withdrawalPolicyManager, role.delay));

        role = RolesLib.getRole__setAssetFeeBps();
        multicallCalldata[1] =
            abi.encodeCall(IAccessManager.grantRole, (role.roleId, withdrawalPolicyManager, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__BbvManager() internal {
        address bbvManager = _getProfile__BbvManager();

        bytes[] memory multicallCalldata = new bytes[](3);
        RolesLib.Role memory role;

        role = RolesLib.getRole__setUserRate();
        multicallCalldata[0] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvManager, role.delay));

        role = RolesLib.getRole__setSubVaultRate();
        multicallCalldata[1] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvManager, role.delay));

        role = RolesLib.getRole__claimSurplusInterest();
        multicallCalldata[2] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvManager, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__BbvRebalancer() internal {
        address bbvRebalancer = _getProfile__BbvRebalancer();

        bytes[] memory multicallCalldata = new bytes[](5);
        RolesLib.Role memory role;

        role = RolesLib.getRole__rebalance();
        multicallCalldata[0] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvRebalancer, role.delay));

        role = RolesLib.getRole__setDefaultStrategy();
        multicallCalldata[1] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvRebalancer, role.delay));

        role = RolesLib.getRole__disableDepositsToStrategy();
        multicallCalldata[2] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvRebalancer, role.delay));

        role = RolesLib.getRole__pushFundsToChain();
        multicallCalldata[3] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvRebalancer, role.delay));

        role = RolesLib.getRole__pushFundsToAccountingChain();
        multicallCalldata[4] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvRebalancer, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__BbvGuardian() internal {
        address bbvGuardian = _getProfile__BbvGuardian();

        bytes[] memory multicallCalldata = new bytes[](8);
        RolesLib.Role memory role;

        role = RolesLib.getRole__rebalance();
        multicallCalldata[0] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvGuardian, role.delay));

        role = RolesLib.getRole__removeStrategy();
        multicallCalldata[1] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvGuardian, role.delay));

        role = RolesLib.getRole__rescueTokens();
        multicallCalldata[2] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvGuardian, role.delay));

        role = RolesLib.getRole__disableAllocatorDeposits();
        multicallCalldata[3] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvGuardian, role.delay));

        role = RolesLib.getRole__disableUserDeposits();
        multicallCalldata[4] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvGuardian, role.delay));

        role = RolesLib.getRole__disableSwapInput();
        multicallCalldata[5] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvGuardian, role.delay));

        role = RolesLib.getRole__disableSwapOutput();
        multicallCalldata[6] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvGuardian, role.delay));

        role = RolesLib.getRole__distrustAsset();
        multicallCalldata[7] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvGuardian, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__aTokenVaultRewardClaimer() internal {
        address aTokenVaultRewardClaimer = _getProfile__aTokenVaultRewardClaimer();

        RolesLib.Role memory role = RolesLib.getRole__claimSurplusInterest();

        IAccessManager(_accessManager()).grantRole(role.roleId, aTokenVaultRewardClaimer, role.delay);
    }
}
