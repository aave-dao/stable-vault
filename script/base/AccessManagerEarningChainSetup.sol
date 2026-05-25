// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";

abstract contract AccessManagerEarningChainSetup is AccessManagerBaseSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Targets(address deployer) internal virtual override {
        super._setup_Targets(deployer);
        _setupTarget__EarningChainGateway(deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__EarningChainGateway(address deployer) internal {
        address gateway = getGatewayAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](8);

        roles[0] = RolesConfig.getRole__pushFundsToAccountingChain();
        roles[1] = RolesConfig.getRole__addFundsBridgeAdapter();
        roles[2] = RolesConfig.getRole__removeFundsBridgeAdapter();
        roles[3] = RolesConfig.getRole__addDataOnlyBridgeAdapter();
        roles[4] = RolesConfig.getRole__disableDataOnlyBridgeAdapterSending();
        roles[5] = RolesConfig.getRole__removeDataOnlyBridgeAdapter();
        roles[6] = RolesConfig.getRole__rescueTokens();
        roles[7] = RolesConfig.getRole__rescueNative();

        _setTargetFunctionRoles(gateway, roles);
    }
}
