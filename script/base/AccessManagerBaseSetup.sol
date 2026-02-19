// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {_toSelectorArray} from "test/helpers/TypeHelpers.sol";

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

        // Setup role admins (guardian role becomes admin for each role)
        _setupRoleAdmins();

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

    function _aTokenVaultAddresses() internal view virtual returns (address[] memory);

    function _setup_Targets(address deployer) internal virtual {
        _setupTarget__CcipAdapter(deployer);
        _setupTarget__Allocator(deployer);
        _setupTarget__WithdrawalPolicy(deployer);
        _setupTarget__AssetRegistry(deployer);
        _setupTarget__PriceOracle(deployer);
        _setupTarget__ATokenVaults();
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

    function _setupRoleAdmins() internal {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            multicallCalldata[i] =
                abi.encodeCall(IAccessManager.setRoleAdmin, (roles[i].roleId, roles[i].guardianRoleId));
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

        // Only used on the Accounting Chain (FundsHandler), but granted in both Accounting and Earning Chain setups
        role = RolesLib.getRole__pushFundsToChain();
        multicallCalldata[3] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, rebalancerProfile, role.delay));

        // Only used on the Earning Chain (EarningChainGateway), but granted in both Accounting and Earning Chain setups
        role = RolesLib.getRole__pushFundsToAccountingChain();
        multicallCalldata[4] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, rebalancerProfile, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__Disabler() internal {
        address disablerProfile = _getProfile__Disabler();

        bytes[] memory multicallCalldata = new bytes[](9);
        RolesLib.Role memory role;

        role = RolesLib.getRole__rebalance();
        multicallCalldata[0] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__removeStrategy();
        multicallCalldata[1] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__rescueTokens();
        multicallCalldata[2] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__rescueNative();
        multicallCalldata[3] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__disableAllocatorDeposits();
        multicallCalldata[4] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__disableUserDeposits();
        multicallCalldata[5] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__disableSwapInput();
        multicallCalldata[6] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__disableSwapOutput();
        multicallCalldata[7] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        role = RolesLib.getRole__distrustAsset();
        multicallCalldata[8] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, disablerProfile, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__ATokenVaultRewardClaimer() internal {
        address aTokenVaultRewardClaimer = _getProfile__ATokenVaultRewardClaimer();

        RolesLib.Role memory role = RolesLib.getRole__claimMerklRewards();

        IAccessManager(_accessManager()).grantRole(role.roleId, aTokenVaultRewardClaimer, role.delay);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__CcipAdapter(address deployer) internal {
        address ccipAdapter = getCcipAdapterAddress(deployer);
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](5);

        role = RolesLib.getRole__setDestinationChainAdapter();
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (ccipAdapter, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__setChainSelector();
        multicallCalldata[1] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (ccipAdapter, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__rescueNative();
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (ccipAdapter, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__replayFundsReceiving();
        multicallCalldata[3] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (ccipAdapter, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__rescueTokens();
        multicallCalldata[4] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (ccipAdapter, _toSelectorArray(role.selector), role.roleId)
        );

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupTarget__Allocator(address deployer) internal {
        address allocator = getAllocatorAddress(deployer);
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](6);

        role = RolesLib.getRole__rebalance();
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (allocator, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__addStrategy();
        multicallCalldata[1] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (allocator, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__removeStrategy();
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (allocator, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__disableDepositsToStrategy();
        multicallCalldata[3] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (allocator, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__setDefaultStrategy();
        multicallCalldata[4] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (allocator, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__enableDepositsToStrategy();
        multicallCalldata[5] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (allocator, _toSelectorArray(role.selector), role.roleId)
        );

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupTarget__WithdrawalPolicy(address deployer) internal {
        address withdrawalPolicy = getWithdrawalPolicyAddress(deployer);
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](3);

        role = RolesLib.getRole__setAssetFeeBps();
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (withdrawalPolicy, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__setDefaultFeeBps();
        multicallCalldata[1] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (withdrawalPolicy, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__setSigner();
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (withdrawalPolicy, _toSelectorArray(role.selector), role.roleId)
        );

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupTarget__AssetRegistry(address deployer) internal {
        address assetRegistry = getAssetRegistryAddress(deployer);
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](11);

        role = RolesLib.getRole__setAssetConfig();
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__disableAllocatorDeposits();
        multicallCalldata[1] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__disableSwapInput();
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__disableSwapOutput();
        multicallCalldata[3] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__disableUserDeposits();
        multicallCalldata[4] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__enableAllocatorDeposits();
        multicallCalldata[5] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__enableSwapInput();
        multicallCalldata[6] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__enableSwapOutput();
        multicallCalldata[7] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__enableUserDeposits();
        multicallCalldata[8] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__trustAsset();
        multicallCalldata[9] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__distrustAsset();
        multicallCalldata[10] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (assetRegistry, _toSelectorArray(role.selector), role.roleId)
        );

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupTarget__PriceOracle(address deployer) internal {
        address priceOracle = getPriceOracleAddress(deployer);
        RolesLib.Role memory role = RolesLib.getRole__setOracleAdapterForAsset();
        IAccessManager(_accessManager())
            .setTargetFunctionRole(priceOracle, _toSelectorArray(role.selector), role.roleId);
    }

    function _setupTarget__ATokenVaults() internal {
        address[] memory vaults = _aTokenVaultAddresses();
        for (uint256 i = 0; i < vaults.length; i++) {
            _setupTarget__ATokenVault(vaults[i]);
        }
    }

    function _setupTarget__ATokenVault(address vault) internal {
        RolesLib.Role memory role = RolesLib.getRole__claimMerklRewards();
        IAccessManager(_accessManager()).setTargetFunctionRole(vault, _toSelectorArray(role.selector), role.roleId);
    }
}
