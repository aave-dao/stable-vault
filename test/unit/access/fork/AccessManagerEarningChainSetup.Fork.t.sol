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
    // OVERRIDES — address getters point to setup script constants / Create3 computations
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _accessManager() internal view override returns (address) {
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
