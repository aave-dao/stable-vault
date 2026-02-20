// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";

abstract contract AccessManagerAccountingChainSetup is AccessManagerBaseSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    //////////////// Admin Profiles ////////////////
    // TODO: Set as deployer address for VNet, but needs to be changed to the high threshold multisig later
    address constant HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE = address(0xBB700dA5CCC9Ec5605780Fc40695f1206B090303);
    // TODO: Set as deployer address for VNet, but needs to be changed to the medium threshold multisig later
    address constant MED_THRESHOLD_MULTISIG_ADMIN_PROFILE = address(0xBB700dA5CCC9Ec5605780Fc40695f1206B090303);

    //////////////// Operational Profiles ////////////////
    address constant WITHDRAWAL_POLICY_MANAGER_PROFILE = address(0);
    address constant STABLE_VAULT_MANAGER_PROFILE = address(0);
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

    function _getProfile__StableVaultManager() internal pure virtual returns (address) {
        return STABLE_VAULT_MANAGER_PROFILE;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Profiles() internal virtual override {
        super._setup_Profiles();
        _setupProfile__StableVaultManager();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Targets(address deployer) internal virtual override {
        super._setup_Targets(deployer);
        _setupTarget__StableVault(deployer);
        _setupTarget__FundsHandler(deployer);
        _setupTarget__AccountingChainGateway(deployer);
        _setupTarget__ChainBalanceOracle(deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupProfile__StableVaultManager() internal {
        address stableVaultManager = _getProfile__StableVaultManager();
        require(stableVaultManager != address(0), "StableVaultManager profile address not set");

        RolesLib.Role[] memory roles = new RolesLib.Role[](4);

        roles[0] = RolesLib.getRole__setUserRate();
        roles[1] = RolesLib.getRole__setSubVaultRate();
        roles[2] = RolesLib.getRole__claimSurplusInterest();
        roles[3] = RolesLib.getRole__setDefaultSubVault();

        _grantRolesToProfile(stableVaultManager, roles);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__StableVault(address deployer) internal {
        address stableVault = getStableVaultAddress(deployer);

        RolesLib.Role[] memory roles = new RolesLib.Role[](7);

        roles[0] = RolesLib.getRole__setUserRate();
        roles[1] = RolesLib.getRole__setSubVaultRate();
        roles[2] = RolesLib.getRole__setDefaultSubVault();
        roles[3] = RolesLib.getRole__claimSurplusInterest();
        roles[4] = RolesLib.getRole__setTreasury();
        roles[5] = RolesLib.getRole__rescueNative();
        roles[6] = RolesLib.getRole__rescueTokens();

        _setTargetFunctionRoles(stableVault, roles);
    }

    function _setupTarget__FundsHandler(address deployer) internal {
        address fundsHandler = getFundsHandlerAddress(deployer);

        RolesLib.Role[] memory roles = new RolesLib.Role[](5);

        roles[0] = RolesLib.getRole__pushFundsToChain();
        roles[1] = RolesLib.getRole__rescueTokens();
        roles[2] = RolesLib.getRole__rescueNative();
        roles[3] = RolesLib.getRole__addEarningChain();
        roles[4] = RolesLib.getRole__removeEarningChain();

        _setTargetFunctionRoles(fundsHandler, roles);
    }

    function _setupTarget__AccountingChainGateway(address deployer) internal {
        address gateway = getGatewayAddress(deployer);

        RolesLib.Role[] memory roles = new RolesLib.Role[](5);

        roles[0] = RolesLib.getRole__addBridgeAdapter();
        roles[1] = RolesLib.getRole__removeBridgeAdapter();
        roles[2] = RolesLib.getRole__setDefaultBridgeAdapter();
        roles[3] = RolesLib.getRole__rescueTokens();
        roles[4] = RolesLib.getRole__rescueNative();

        _setTargetFunctionRoles(gateway, roles);
    }

    function _setupTarget__ChainBalanceOracle(address deployer) internal {
        address chainBalanceOracle = getChainBalanceOracleAddress(deployer);

        RolesLib.Role[] memory roles = new RolesLib.Role[](1);

        roles[0] = RolesLib.getRole__setChainBalanceOracleAdapter();

        _setTargetFunctionRoles(chainBalanceOracle, roles);
    }
}
