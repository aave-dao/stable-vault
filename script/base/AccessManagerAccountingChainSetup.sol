// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {_toSelectorArray} from "test/helpers/TypeHelpers.sol";

abstract contract AccessManagerAccountingChainSetup is AccessManagerBaseSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    //////////////// Admin Profiles ////////////////
    address constant HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE = address(0);
    address constant MED_THRESHOLD_MULTISIG_ADMIN_PROFILE = address(0);

    //////////////// Operational Profiles ////////////////
    address constant WITHDRAWAL_POLICY_MANAGER_PROFILE = address(0);
    address constant BBV_MANAGER_PROFILE = address(0);
    address constant REBALANCER_PROFILE = address(0);
    address constant DISABLER_PROFILE = address(0);
    address constant ATOKEN_VAULT_REWARD_CLAIMER_PROFILE = address(0);

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _getProfile__MainAdmin() internal pure virtual override returns (address) {
        return HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE;
    }

    function _getProfile__SecondaryAdmin() internal pure virtual override returns (address) {
        return MED_THRESHOLD_MULTISIG_ADMIN_PROFILE;
    }

    function _getProfile__WithdrawalPolicyManager() internal pure virtual override returns (address) {
        return WITHDRAWAL_POLICY_MANAGER_PROFILE;
    }

    function _getProfile__Rebalancer() internal pure virtual override returns (address) {
        return REBALANCER_PROFILE;
    }

    function _getProfile__Disabler() internal pure virtual override returns (address) {
        return DISABLER_PROFILE;
    }

    function _getProfile__ATokenVaultRewardClaimer() internal pure virtual override returns (address) {
        return ATOKEN_VAULT_REWARD_CLAIMER_PROFILE;
    }

    //////////////// Special Accounting Chain Profiles

    function _getProfile__BbvManager() internal pure virtual returns (address) {
        return BBV_MANAGER_PROFILE;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Profiles() internal virtual override {
        super._setup_Profiles();
        _setupProfile__BbvManager();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Targets(address deployer) internal virtual override {
        super._setup_Targets(deployer);
        _setupTarget__Bbv(deployer);
        _setupTarget__FundsHandler(deployer);
        _setupTarget__AccountingChainGateway(deployer);
        _setupTarget__ChainBalanceOracle(deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupProfile__BbvManager() internal {
        address bbvManager = _getProfile__BbvManager();

        bytes[] memory multicallCalldata = new bytes[](4);
        RolesLib.Role memory role;

        role = RolesLib.getRole__setUserRate();
        multicallCalldata[0] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvManager, role.delay));

        role = RolesLib.getRole__setSubVaultRate();
        multicallCalldata[1] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvManager, role.delay));

        role = RolesLib.getRole__claimSurplusInterest();
        multicallCalldata[2] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvManager, role.delay));

        role = RolesLib.getRole__setDefaultSubVault();
        multicallCalldata[3] = abi.encodeCall(IAccessManager.grantRole, (role.roleId, bbvManager, role.delay));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__Bbv(address deployer) internal {
        address bbv = getBasedBoostedVaultAddress(deployer);
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](6);

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

        role = RolesLib.getRole__rescueNative();
        multicallCalldata[4] =
            abi.encodeCall(IAccessManager.setTargetFunctionRole, (bbv, _toSelectorArray(role.selector), role.roleId));

        role = RolesLib.getRole__rescueTokens();
        multicallCalldata[5] =
            abi.encodeCall(IAccessManager.setTargetFunctionRole, (bbv, _toSelectorArray(role.selector), role.roleId));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupTarget__FundsHandler(address deployer) internal {
        address fundsHandler = getFundsHandlerAddress(deployer);
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](5);

        role = RolesLib.getRole__pushFundsToChain();
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (fundsHandler, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__rescueTokens();
        multicallCalldata[1] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (fundsHandler, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__rescueNative();
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (fundsHandler, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__addEarningChain();
        multicallCalldata[3] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (fundsHandler, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__removeEarningChain();
        multicallCalldata[4] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (fundsHandler, _toSelectorArray(role.selector), role.roleId)
        );

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupTarget__AccountingChainGateway(address deployer) internal {
        address gateway = getGatewayAddress(deployer);
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](5);

        role = RolesLib.getRole__addBridgeAdapter();
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (gateway, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__removeBridgeAdapter();
        multicallCalldata[1] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (gateway, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__setDefaultBridgeAdapter();
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (gateway, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__rescueTokens();
        multicallCalldata[3] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (gateway, _toSelectorArray(role.selector), role.roleId)
        );

        role = RolesLib.getRole__rescueNative();
        multicallCalldata[4] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (gateway, _toSelectorArray(role.selector), role.roleId)
        );

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupTarget__ChainBalanceOracle(address deployer) internal {
        address chainBalanceOracle = getChainBalanceOracleAddress(deployer);
        RolesLib.Role memory role = RolesLib.getRole__setChainBalanceOracleAdapter();
        IAccessManager(_accessManager())
            .setTargetFunctionRole(chainBalanceOracle, _toSelectorArray(role.selector), role.roleId);
    }
}
