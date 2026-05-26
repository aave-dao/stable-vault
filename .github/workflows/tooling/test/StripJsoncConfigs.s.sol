// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {JsoncLib} from "script/libraries/JsoncLib.sol";

/// @notice Strips `//` and `/* */` comments from the deployment-config `.jsonc` files in place, using the same
/// `JsoncLib.stripComments` routine that the Solidity-side reads use. Replaces the older bash sed pass, which only
/// handled trailing `//` and could diverge from the Solidity stripper (and accept files that worked locally but
/// failed in CI).
///
/// Run from the repo root via `forge script .github/workflows/tooling/test/StripJsoncConfigs.s.sol` (no broadcast).
/// Designed to be safe to run multiple times — already-stripped files are written back unchanged. Missing config
/// files are skipped.
contract StripJsoncConfigs is Script {
    string[] private _configs = [
        "config/deployment-config.prod.jsonc",
        "config/deployment-config.preprod.jsonc",
        "config/deployment-config.staging.jsonc"
    ];

    function run() external {
        for (uint256 i = 0; i < _configs.length; i++) {
            string memory path = _configs[i];
            // forge-lint: disable-next-line(unsafe-cheatcode)
            if (!vm.exists(path)) {
                continue;
            }
            // forge-lint: disable-next-line(unsafe-cheatcode)
            string memory stripped = JsoncLib.stripComments(vm.readFile(path));
            // forge-lint: disable-next-line(unsafe-cheatcode)
            vm.writeFile(path, stripped);
        }
    }
}
