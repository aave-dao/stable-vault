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

    function _validateProfileAddresses() internal view virtual override {
        super._validateProfileAddresses();
        require(_getProfile__StableVaultManager() != address(0), "StableVaultManager profile address not set");
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

        _grantRolesToProfile(stableVaultManager, getProfileRoles__StableVaultManager());
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
        roles[5] = RolesConfig.getRole__rescueTokens();
        roles[6] = RolesConfig.getRole__rescueNative();

        _setTargetFunctionRoles(stableVault, roles);
    }

    function _setupTarget__FundsHandler(address deployer) internal {
        address fundsHandler = getFundsHandlerAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](5);

        roles[0] = RolesConfig.getRole__pushFundsToChain();
        roles[1] = RolesConfig.getRole__addEarningChain();
        roles[2] = RolesConfig.getRole__removeEarningChain();
        roles[3] = RolesConfig.getRole__rescueTokens();
        roles[4] = RolesConfig.getRole__rescueNative();

        _setTargetFunctionRoles(fundsHandler, roles);
    }

    function _setupTarget__AccountingChainGateway(address deployer) internal {
        address gateway = getGatewayAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](7);

        roles[0] = RolesConfig.getRole__addFundsBridgeAdapter();
        roles[1] = RolesConfig.getRole__removeFundsBridgeAdapter();
        roles[2] = RolesConfig.getRole__addDataOnlyBridgeAdapter();
        roles[3] = RolesConfig.getRole__initiateDataOnlyBridgeAdapterRemoval();
        roles[4] = RolesConfig.getRole__finalizeDataOnlyBridgeAdapterRemoval();
        roles[5] = RolesConfig.getRole__rescueTokens();
        roles[6] = RolesConfig.getRole__rescueNative();

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

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](8);

        // Deposit rate limit (raise/lower pairs adjacent)
        roles[0] = RolesConfig.getRole__raiseDepositCapacity();
        roles[1] = RolesConfig.getRole__lowerDepositCapacity();
        roles[2] = RolesConfig.getRole__raiseDepositRefillRate();
        roles[3] = RolesConfig.getRole__lowerDepositRefillRate();
        // Global deposit rate limit (raise/lower pairs adjacent)
        roles[4] = RolesConfig.getRole__raiseGlobalDepositCapacity();
        roles[5] = RolesConfig.getRole__lowerGlobalDepositCapacity();
        roles[6] = RolesConfig.getRole__raiseGlobalDepositRefillRate();
        roles[7] = RolesConfig.getRole__lowerGlobalDepositRefillRate();

        _setTargetFunctionRoles(depositPolicy, roles);
    }
}
