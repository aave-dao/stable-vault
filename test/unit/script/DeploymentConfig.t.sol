// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeploymentConfig} from "script/base/DeploymentConfig.sol";

contract DeploymentConfigHarness is DeploymentConfig {
    function _configPath() internal pure override returns (string memory) {
        return "test/resources/config/config-uint-bounds.json";
    }

    function configUint8(string memory key) external view returns (uint8) {
        return _configUint8(key);
    }

    function configUint16(string memory key) external view returns (uint16) {
        return _configUint16(key);
    }

    function configUint32(string memory key) external view returns (uint32) {
        return _configUint32(key);
    }

    function configUint64(string memory key) external view returns (uint64) {
        return _configUint64(key);
    }

    function configUint128(string memory key) external view returns (uint128) {
        return _configUint128(key);
    }
}

contract DeploymentConfigTest is Test {
    DeploymentConfigHarness internal _config = new DeploymentConfigHarness();

    function test_configUintN_acceptsMaxValues() public view {
        assertEq(_config.configUint8(".uint8"), type(uint8).max);
        assertEq(_config.configUint16(".uint16"), type(uint16).max);
        assertEq(_config.configUint32(".uint32"), type(uint32).max);
        assertEq(_config.configUint64(".uint64"), type(uint64).max);
        assertEq(_config.configUint128(".uint128"), type(uint128).max);
    }

    function test_configUint8_revertsIfValueExceedsTypeMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentConfig.ConfigUintTooLarge.selector, ".uint8Overflow", 256, type(uint8).max)
        );
        _config.configUint8(".uint8Overflow");
    }

    function test_configUint16_revertsIfValueExceedsTypeMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfig.ConfigUintTooLarge.selector, ".uint16Overflow", 65536, type(uint16).max
            )
        );
        _config.configUint16(".uint16Overflow");
    }

    function test_configUint32_revertsIfValueExceedsTypeMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfig.ConfigUintTooLarge.selector, ".uint32Overflow", 4294967296, type(uint32).max
            )
        );
        _config.configUint32(".uint32Overflow");
    }

    function test_configUint64_revertsIfValueExceedsTypeMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfig.ConfigUintTooLarge.selector, ".uint64Overflow", 18446744073709551616, type(uint64).max
            )
        );
        _config.configUint64(".uint64Overflow");
    }

    function test_configUint128_revertsIfValueExceedsTypeMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfig.ConfigUintTooLarge.selector,
                ".uint128Overflow",
                340282366920938463463374607431768211456,
                type(uint128).max
            )
        );
        _config.configUint128(".uint128Overflow");
    }
}
