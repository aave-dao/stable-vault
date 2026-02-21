// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";

abstract contract AccessManagerEarningChainSetup is AccessManagerBaseSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Targets(address deployer) internal virtual override {
        super._setup_Targets(deployer);
        _setupTarget__EarningChainGateway(deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__EarningChainGateway(address deployer) internal {
        address gateway = getGatewayAddress(deployer);

        RolesLib.Role[] memory roles = new RolesLib.Role[](6);

        roles[0] = RolesLib.getRole__addBridgeAdapter();
        roles[1] = RolesLib.getRole__removeBridgeAdapter();
        roles[2] = RolesLib.getRole__setDefaultBridgeAdapter();
        roles[3] = RolesLib.getRole__rescueTokens();
        roles[4] = RolesLib.getRole__rescueNative();
        roles[5] = RolesLib.getRole__pushFundsToAccountingChain();

        _setTargetFunctionRoles(gateway, roles);
    }
}
