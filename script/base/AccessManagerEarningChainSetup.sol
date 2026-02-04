// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {_toSelectorArray} from "test/helpers/TypeHelpers.sol";

abstract contract AccessManagerEarningChainSetup is AccessManagerBaseSetup {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    //////////////// Admin Profiles ////////////////
    address constant HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE = address(0);
    address constant MED_THRESHOLD_MULTISIG_ADMIN_PROFILE = address(0);

    //////////////// Operational Profiles ////////////////
    address constant WITHDRAWAL_POLICY_MANAGER_PROFILE = address(0);
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

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Targets(address deployer) internal virtual override {
        super._setup_Targets(deployer);
        _setupTarget__EarningChainGateway(deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__EarningChainGateway(address deployer) internal {
        address earningChainGateway = getGatewayAddress(deployer);
        RolesLib.Role memory role;
        bytes[] memory multicallCalldata = new bytes[](4);

        // role = RolesLib.getRole__setUserRate();
        // multicallCalldata[0] =
        //     abi.encodeCall(IAccessManager.setTargetFunctionRole, (bbv, _toSelectorArray(role.selector),
        // role.roleId));

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }
}
