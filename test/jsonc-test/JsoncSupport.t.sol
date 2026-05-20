// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeploymentConfig} from "script/base/DeploymentConfig.sol";

contract JsoncConfigHarness is DeploymentConfig {
    string internal _path;

    constructor(string memory path) {
        _path = path;
    }

    function _configPath() internal view override returns (string memory) {
        return _path;
    }

    function configString(string memory key) external view returns (string memory) {
        return _configString(key);
    }

    function configUint(string memory key) external view returns (uint256) {
        return _configUint(key);
    }
}

contract JsoncSupportTest is Test {
    function test_configReaderAllowsJsoncLineComments() public {
        JsoncConfigHarness config = new JsoncConfigHarness("test/jsonc-test/fixture.jsonc");

        assertEq(config.configString(".name"), "test");
        assertEq(config.configUint(".value"), 42);
        assertEq(config.configString(".nested.key"), "hello");
        assertEq(config.configString(".url"), "https://example.com/a//b");
    }

    function test_configReaderAllowsCommentsInJsonFile() public {
        JsoncConfigHarness config = new JsoncConfigHarness("test/jsonc-test/fixture-comments.json");

        assertEq(config.configString(".name"), "test");
        assertEq(config.configUint(".value"), 42);
    }

    function test_deploymentConfigsAllowInlineComments() public {
        _assertDeploymentConfigParses("config/deployment-config.preprod.json");
        _assertDeploymentConfigParses("config/deployment-config.staging.json");
        _assertDeploymentConfigParses("config/deployment-config.prod.json");
    }

    function _assertDeploymentConfigParses(string memory path) internal {
        JsoncConfigHarness config = new JsoncConfigHarness(path);

        assertEq(config.configUint(".slippageCoverageVault.maxSlippageBps"), 50);
        assertEq(config.configUint(".slippageCoverageVault.perAssetCaps.usdc.pullCapPerTx"), 1e6);
        assertEq(config.configUint(".accountingChain.depositPolicy.perAssetLimits.gho.capacity"), 100e18);
        assertEq(config.configUint(".accountingChain.withdrawalExecutionPolicy.redemptionLimit.capacity"), 200e27);
    }
}
