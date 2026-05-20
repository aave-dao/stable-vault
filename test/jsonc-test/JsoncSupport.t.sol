// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeploymentConfig} from "script/base/DeploymentConfig.sol";
import {JsoncLib} from "script/libraries/JsoncLib.sol";

contract JsoncConfigHarness is DeploymentConfig {
    string internal _path;

    constructor(string memory path) {
        _path = path;
    }

    function _configPath() internal view override returns (string memory) {
        return _path;
    }

    /// The base impl honors `JSONC_PRESTRIPPED` so CI can skip the Solidity stripper after a
    /// pre-strip step. These tests exist to verify the stripper itself, so the harness ignores
    /// the env flag and always strips.
    function _readConfig() internal view override returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return JsoncLib.stripComments(vm.readFile(_path));
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
        JsoncConfigHarness config = new JsoncConfigHarness("test/resources/jsonc/fixture.jsonc");

        assertEq(config.configString(".name"), "test");
        assertEq(config.configUint(".value"), 42);
        assertEq(config.configString(".nested.key"), "hello");
        assertEq(config.configString(".url"), "https://example.com/a//b");
    }

    function test_configReaderAllowsCommentsInJsonFile() public {
        JsoncConfigHarness config = new JsoncConfigHarness("test/resources/jsonc/fixture-comments.json");

        assertEq(config.configString(".name"), "test");
        assertEq(config.configUint(".value"), 42);
    }
}
