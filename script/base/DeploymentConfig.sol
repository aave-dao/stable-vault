// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

abstract contract DeploymentConfig {
    Vm private constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _configPath() internal view virtual returns (string memory) {
        return "config/deployment-config.staging.json";
    }

    function _readConfig() internal view returns (string memory) {
        return _VM.readFile(_configPath());
    }

    function _configAddress(string memory key) internal view returns (address) {
        return _VM.parseJsonAddress(_readConfig(), key);
    }

    function _configUint(string memory key) internal view returns (uint256) {
        return _VM.parseJsonUint(_readConfig(), key);
    }

    function _configString(string memory key) internal view returns (string memory) {
        return _VM.parseJsonString(_readConfig(), key);
    }

    function _configBool(string memory key) internal view returns (bool) {
        return _VM.parseJsonBool(_readConfig(), key);
    }
}
