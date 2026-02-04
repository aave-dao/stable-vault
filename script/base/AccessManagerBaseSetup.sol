// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";

abstract contract AccessManagerBaseSetup is Create3AddressBook {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupAccessManager(address deployer) internal {
        IAccessManager accessManager = IAccessManager(_accessManager());

        // Setup all profiles by granting roles to them, with their respective execution delays
        _setup_Profiles();

        // Setup role hierarchy by configuring role guardians
        _setupRoleGuardians();

        // Setup role granting delays
        _setupRoleGrantingDelays();

        // Setup the ADMIN_ROLE delay
        accessManager.setTargetAdminDelay(address(accessManager), RolesLib.CRITICAL_DELAY);

        // Setup the link between target and its allowed role, with
        _setup_Targets(deployer);

        // Revoke deployer's access to ADMIN_ROLE
        accessManager.revokeRole(RolesLib.ADMIN_ROLE, deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _accessManager() internal view virtual returns (address);

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _getProfile__MainAdmin() internal pure virtual returns (address);

    function _getProfile__SecondaryAdmin() internal pure virtual returns (address);

    function _getProfile__WithdrawalPolicyManager() internal pure virtual returns (address);

    function _getProfile__Rebalancer() internal pure virtual returns (address);

    function _getProfile__Disabler() internal pure virtual returns (address);

    function _getProfile__ATokenVaultRewardClaimer() internal pure virtual returns (address);

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Profiles() internal virtual {
        _setupProfile__MainAdmin();
        _setupProfile__SecondaryAdmin();
        _setupProfile__WithdrawalPolicyManager();
        _setupProfile__Rebalancer();
        _setupProfile__Disabler();
        _setupProfile__ATokenVaultRewardClaimer();
    }

    function _setup_Targets(address deployer) internal virtual {}

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
        address mainAdminProfile = _getProfile__MainAdmin();

        RolesLib.Role[] memory functionBasedRoles = RolesLib.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](functionBasedRoles.length + 3);

        // Grant ADMIN_ROLE
        multicallCalldata[0] =
            abi.encodeCall(IAccessManager.grantRole, (RolesLib.ADMIN_ROLE, mainAdminProfile, RolesLib.CRITICAL_DELAY));

        // Grant All Role-Guardian roles
        multicallCalldata[1] = abi.encodeCall(
            IAccessManager.grantRole, (RolesLib.ADMIN_ROLE_GUARDIAN_ROLE, mainAdminProfile, RolesLib.NO_DELAY)
        );
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.grantRole, (RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE, mainAdminProfile, RolesLib.NO_DELAY)
        );

        // Grant All Function-Based roles
        for (uint256 i = 0; i < functionBasedRoles.length; i++) {
            multicallCalldata[i + 3] = abi.encodeCall(
                IAccessManager.grantRole, (functionBasedRoles[i].roleId, mainAdminProfile, functionBasedRoles[i].delay)
            );
        }

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__SecondaryAdmin() internal {
        address secondaryAdminProfile = _getProfile__SecondaryAdmin();

        RolesLib.Role[] memory functionBasedRoles = RolesLib.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](functionBasedRoles.length + 1);

        // Grant Operation-Role Guardian role
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.grantRole,
            (RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE, secondaryAdminProfile, RolesLib.NO_DELAY)
        );

        // Grant All Function-Based roles
        for (uint256 i = 0; i < functionBasedRoles.length; i++) {
            multicallCalldata[i + 1] = abi.encodeCall(
                IAccessManager.grantRole,
                (functionBasedRoles[i].roleId, secondaryAdminProfile, functionBasedRoles[i].delay)
            );
        }

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__WithdrawalPolicyManager() internal {
        address withdrawalPolicyManagerProfile = _getProfile__WithdrawalPolicyManager();

        bytes[] memory multicallCalldata = new bytes[](2);
        RolesLib.Role memory role;

        role = RolesLib.getRole__setDefaultFeeBps();
        multicallCalldata[0] =
            abi.encodeCall(IAccessManager.grantRole, (role.roleId, withdrawalPolicyManagerProfile, role.delay));

        role = RolesLib.getRole__setAssetFeeBps();
        multicallCalldata[1] =
            abi.encodeCall(IAccessManager.grantRole, (role.roleId, withdrawalPolicyManagerProfile, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__Rebalancer() internal {
        address rebalancerProfile = _getProfile__Rebalancer();

        bytes[] memory multicallCalldata = new bytes[](5);
        RolesLib.Role memory role;

        role = RolesLib.getRole__rebalance();
        multicallCalldata[0] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, rebalancerProfile, role.delay));

        role = RolesLib.getRole__setDefaultStrategy();
        multicallCalldata[1] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, rebalancerProfile, role.delay));

        role = RolesLib.getRole__disableDepositsToStrategy();
        multicallCalldata[2] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, rebalancerProfile, role.delay));

        // This role is only used on the Accounting Chain, but granted in both Accounting and Earning Chain setups
        role = RolesLib.getRole__pushFundsToChain();
        multicallCalldata[3] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, rebalancerProfile, role.delay));

        // This role is only used on the Earning Chain, but granted in both Accounting and Earning Chain setups
        role = RolesLib.getRole__pushFundsToAccountingChain();
        multicallCalldata[4] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, rebalancerProfile, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__Disabler() internal {
        address disablerProfile = _getProfile__Disabler();

        bytes[] memory multicallCalldata = new bytes[](8);
        RolesLib.Role memory role;

        role = RolesLib.getRole__rebalance();
        multicallCalldata[0] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__removeStrategy();
        multicallCalldata[1] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__rescueTokens();
        multicallCalldata[2] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__disableAllocatorDeposits();
        multicallCalldata[3] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__disableUserDeposits();
        multicallCalldata[4] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__disableSwapInput();
        multicallCalldata[5] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__disableSwapOutput();
        multicallCalldata[6] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__distrustAsset();
        multicallCalldata[7] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__ATokenVaultRewardClaimer() internal {
        address aTokenVaultRewardClaimer = _getProfile__ATokenVaultRewardClaimer();

        RolesLib.Role memory role = RolesLib.getRole__claimSurplusInterest();

        IAccessManager(_accessManager()).grantRole(role.roleId, aTokenVaultRewardClaimer, role.delay);
    }
}
