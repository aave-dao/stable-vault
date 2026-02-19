// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {RolesLib} from "script/libraries/RolesLib.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";

import {AccessManagerEarningChainSetupTest} from "test/unit/access/AccessManagerEarningChainSetup.t.sol";

contract AccessManagerEarningChainSetupForkTest is AccessManagerEarningChainSetupTest {
    // Turn on in order to run the tests on a fork, otherwise they will be skipped.
    bool immutable FORKING = false;

    function setUp() public override {
        vm.skip(!FORKING);
        vm.createSelectFork(vm.envString("FORK_URL"));
        vm.warp(block.timestamp + RolesLib.CRITICAL_DELAY + 1);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // OVERRIDES — profile getters point to setup script constants
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _getProfile__MainAdmin() internal pure override returns (address) {
        return HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE;
    }

    function _getProfile__SecondaryAdmin() internal pure override returns (address) {
        return MED_THRESHOLD_MULTISIG_ADMIN_PROFILE;
    }

    function _getProfile__WithdrawalPolicyManager() internal pure override returns (address) {
        return WITHDRAWAL_POLICY_MANAGER_PROFILE;
    }

    function _getProfile__Rebalancer() internal pure override returns (address) {
        return REBALANCER_PROFILE;
    }

    function _getProfile__Disabler() internal pure override returns (address) {
        return DISABLER_PROFILE;
    }

    function _getProfile__ATokenVaultRewardClaimer() internal pure override returns (address) {
        return ATOKEN_VAULT_REWARD_CLAIMER_PROFILE;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // OVERRIDES — address getters point to setup script constants / Create3 computations
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _getDeployer() internal pure override returns (address) {
        return address(0xBB700dA5CCC9Ec5605780Fc40695f1206B090303);
    }

    function _accessManager() internal pure override returns (address) {
        return getAccessManagerAddress(_getDeployer());
    }

    function _aTokenVaultAddresses()
        internal
        view
        override(AccessManagerEarningChainSetupTest)
        returns (address[] memory)
    {
        IAllocator allocator = IAllocator(getAllocatorAddress(_getDeployer()));
        address[] memory vaults = new address[](2);
        vaults[0] = allocator.getDefaultStrategy(USDC);
        vaults[1] = allocator.getDefaultStrategy(USDT);
        return vaults;
    }
}
