// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

abstract contract DeploymentConfig is Script {
    function _configPath() internal view virtual returns (string memory);

    function _readConfig() internal view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.readFile(_configPath());
    }

    function _configAddress(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(_readConfig(), key);
    }

    function _configUint(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(_readConfig(), key);
    }

    function _configString(string memory key) internal view returns (string memory) {
        return vm.parseJsonString(_readConfig(), key);
    }

    function _configBool(string memory key) internal view returns (bool) {
        return vm.parseJsonBool(_readConfig(), key);
    }
}
