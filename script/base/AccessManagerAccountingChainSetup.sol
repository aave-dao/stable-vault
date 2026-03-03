// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";

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
