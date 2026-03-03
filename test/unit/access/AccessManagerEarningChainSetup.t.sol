// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {EarningChainDeployment} from "script/EarningChainDeployment.s.sol";
import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {AccessManagerEarningChainSetup} from "script/base/AccessManagerEarningChainSetup.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";

import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";

import {AccessManagerSetupBaseTest} from "test/unit/access/AccessManagerSetupBaseTest.sol";

contract AccessManagerEarningChainSetupTest is AccessManagerSetupBaseTest, EarningChainDeployment {
    function setUp() public virtual {
        _deployCreateXTo(Create3AddressLib.CREATEX_ADDRESS);
        vm.startPrank(_deployer());
        _deployContracts();
        _setupAccessManager(_deployer());
        vm.stopPrank();
        vm.warp(block.timestamp + CRITICAL_DELAY + 1);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // OVERRIDES
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _logDeployment(string memory, string memory, address)
        internal
        virtual
        override(AccessManagerBaseSetup, EarningChainDeployment)
    {}

    function _aTokenVaultAddresses()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, EarningChainDeployment)
        returns (address[] memory)
    {
        address[] memory vaults = new address[](1);
        vaults[0] = address(uint160(uint256(keccak256("test.aTokenVault"))));
        return vaults;
    }

    function _setup_Targets(address deployer)
        internal
        virtual
        override(AccessManagerBaseSetup, AccessManagerEarningChainSetup)
    {
        super._setup_Targets(deployer);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // CHAIN-SPECIFIC TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_targetSetup_earningChainGateway() public view {
        address gateway = getGatewayAddress(_deployer());

        _assertTargetFunctionRole(
            gateway, IChainGateway.addBridgeAdapter.selector, RolesLib.getRole__addBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway, IChainGateway.removeBridgeAdapter.selector, RolesLib.getRole__removeBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway, IChainGateway.setDefaultBridgeAdapter.selector, RolesLib.getRole__setDefaultBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway, IRescuableToken.rescueTokens.selector, RolesLib.getRole__rescueTokens().roleId
        );
        _assertTargetFunctionRole(
            gateway, IRescuableNative.rescueNative.selector, RolesLib.getRole__rescueNative().roleId
        );
        _assertTargetFunctionRole(
            gateway,
            IEarningChainGateway.pushFundsToAccountingChain.selector,
            RolesLib.getRole__pushFundsToAccountingChain().roleId
        );
    }
}
