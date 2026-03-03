// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccountingChainDeployment} from "script/AccountingChainDeployment.s.sol";
import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";

import {AccessManagerAccountingChainSetupTest} from "test/unit/access/AccessManagerAccountingChainSetup.t.sol";

contract AccessManagerAccountingChainSetupForkTest is AccessManagerAccountingChainSetupTest {
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

    function _accessManager()
        internal
        view
        override(AccessManagerBaseSetup, AccountingChainDeployment)
        returns (address)
    {
        return getAccessManagerAddress(_deployer());
    }

    function _aTokenVaultAddresses()
        internal
        view
        override(AccessManagerAccountingChainSetupTest)
        returns (address[] memory)
    {
        IAllocator allocator = IAllocator(getAllocatorAddress(_deployer()));
        address[] memory vaults = new address[](2);
        vaults[0] = allocator.getDefaultStrategy(_gho());
        vaults[1] = allocator.getDefaultStrategy(_usdc());
        return vaults;
    }
}
