// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AccessManager} from "openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";

contract AccessManagerAdiAdapterSetupTest is AccessManagerBaseSetup, Test {
    address internal _accessManagerAddress;

    function setUp() public {
        _accessManagerAddress = address(new AccessManager(address(this)));
        _setupTarget__AdiAdapter(_deployer());
    }

    function _configPath() internal pure override returns (string memory) {
        return "test/resources/config/deployment-config.test.json";
    }

    function _accessManager() internal view override returns (address) {
        return _accessManagerAddress;
    }

    function _deployedATokenVaultAddresses() internal pure override returns (address[] memory) {
        return new address[](0);
    }

    function test_targetSetup_adiAdapter() public view {
        address target = getAdiAdapterAddress(_deployer());
        _assertTargetFunctionRole(
            target,
            IBridgeAdapter.setDestinationChainAdapter.selector,
            RolesConfig.getRole__setDestinationChainAdapter().roleId
        );
        _assertTargetFunctionRole(
            target, IRescuableToken.rescueTokens.selector, RolesConfig.getRole__rescueTokens().roleId
        );
        _assertTargetFunctionRole(
            target, IRescuableNative.rescueNative.selector, RolesConfig.getRole__rescueNative().roleId
        );
    }

    function _assertTargetFunctionRole(address target, bytes4 selector, uint64 expectedRoleId) internal view {
        uint64 actual = IAccessManager(_accessManager()).getTargetFunctionRole(target, selector);
        assertEq(actual, expectedRoleId);
    }
}
