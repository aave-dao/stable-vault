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

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](5);

        roles[0] = RolesConfig.getRole__pushFundsToAccountingChain();
        roles[1] = RolesConfig.getRole__addBridgeAdapter();
        roles[2] = RolesConfig.getRole__removeBridgeAdapter();
        roles[3] = RolesConfig.getRole__rescueTokens();
        roles[4] = RolesConfig.getRole__rescueNative();

        _setTargetFunctionRoles(gateway, roles);
    }
}
