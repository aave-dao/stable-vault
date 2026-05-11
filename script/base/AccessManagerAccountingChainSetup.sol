// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";

abstract contract AccessManagerAccountingChainSetup is AccessManagerBaseSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _getProfile__StableVaultManager() internal view virtual returns (address) {
        return _configAddress(".profiles.stableVaultManager");
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
        _setupTarget__DepositPolicy(deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupProfile__StableVaultManager() internal {
        address stableVaultManager = _getProfile__StableVaultManager();
        require(stableVaultManager != address(0), "StableVaultManager profile address not set");

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](4);

        roles[0] = RolesConfig.getRole__setUserRate();
        roles[1] = RolesConfig.getRole__setSubVaultRate();
        roles[2] = RolesConfig.getRole__claimSurplusInterest();
        roles[3] = RolesConfig.getRole__setDefaultSubVault();

        _grantRolesToProfile(stableVaultManager, roles);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__StableVault(address deployer) internal {
        address stableVault = getStableVaultAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](7);

        roles[0] = RolesConfig.getRole__setUserRate();
        roles[1] = RolesConfig.getRole__setSubVaultRate();
        roles[2] = RolesConfig.getRole__setDefaultSubVault();
        roles[3] = RolesConfig.getRole__claimSurplusInterest();
        roles[4] = RolesConfig.getRole__setTreasury();
        roles[5] = RolesConfig.getRole__rescueNative();
        roles[6] = RolesConfig.getRole__rescueTokens();

        _setTargetFunctionRoles(stableVault, roles);
    }

    function _setupTarget__FundsHandler(address deployer) internal {
        address fundsHandler = getFundsHandlerAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](5);

        roles[0] = RolesConfig.getRole__pushFundsToChain();
        roles[1] = RolesConfig.getRole__rescueTokens();
        roles[2] = RolesConfig.getRole__rescueNative();
        roles[3] = RolesConfig.getRole__addEarningChain();
        roles[4] = RolesConfig.getRole__removeEarningChain();

        _setTargetFunctionRoles(fundsHandler, roles);
    }

    function _setupTarget__AccountingChainGateway(address deployer) internal {
        address gateway = getGatewayAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](4);

        roles[0] = RolesConfig.getRole__addBridgeAdapter();
        roles[1] = RolesConfig.getRole__removeBridgeAdapter();
        roles[2] = RolesConfig.getRole__rescueTokens();
        roles[3] = RolesConfig.getRole__rescueNative();

        _setTargetFunctionRoles(gateway, roles);
    }

    function _setupTarget__ChainBalanceOracle(address deployer) internal {
        address chainBalanceOracle = getChainBalanceOracleAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](1);

        roles[0] = RolesConfig.getRole__setChainBalanceOracleAdapter();

        _setTargetFunctionRoles(chainBalanceOracle, roles);
    }

    function _setupTarget__DepositPolicy(address deployer) internal {
        address depositPolicy = getDepositPolicyAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](2);

        roles[0] = RolesConfig.getRole__loosenDepositLimit();
        roles[1] = RolesConfig.getRole__tightenDepositLimit();

        _setTargetFunctionRoles(depositPolicy, roles);
    }
}
