// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";

import {AccessManagerAccountingChainSetup} from "script/base/AccessManagerAccountingChainSetup.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";

/// @notice Resolves the function-based role set and the addresses of every named profile against a chosen env's
/// deployment config, then writes both to JSON. Consumed by `tools/roles/build-roles-json.ts`, which merges per-env
/// dumps with the natspec/profile-grant data it parses out of Solidity. Pick the env with
/// `TARGET_ENV={staging|preprod|prod}`.
///
/// `_accessManager` and `_deployedATokenVaultAddresses` are stubbed out because no side-effecting setup is invoked —
/// this script only reads view functions on the inherited setup contract.
contract DumpRolesScript is AccessManagerAccountingChainSetup {
    function _configPath() internal view override returns (string memory) {
        string memory env = vm.envOr("TARGET_ENV", string("staging"));
        return string.concat("config/deployment-config.", env, ".jsonc");
    }

    function _accessManager() internal pure override returns (address) {
        return address(0);
    }

    function _deployedATokenVaultAddresses() internal pure override returns (address[] memory) {
        return new address[](0);
    }

    function run() external {
        string memory env = vm.envOr("TARGET_ENV", string("staging"));
        Role[] memory roles = getAllFunctionBasedRoles();

        string memory rolesBody = "";
        for (uint256 i = 0; i < roles.length; i++) {
            rolesBody = string.concat(rolesBody, _roleEntry(i, roles[i]), i < roles.length - 1 ? ",\n" : "\n");
        }

        string memory out = string.concat(
            "{\n",
            "  \"env\": \"",
            env,
            "\",\n",
            "  \"deployer\": \"",
            vm.toString(_deployer()),
            "\",\n",
            "  \"lowDelaySeconds\": ",
            vm.toString(uint256(LOW_DELAY)),
            ",\n",
            "  \"mediumDelaySeconds\": ",
            vm.toString(uint256(MEDIUM_DELAY)),
            ",\n",
            "  \"highDelaySeconds\": ",
            vm.toString(uint256(HIGH_DELAY)),
            ",\n",
            "  \"criticalDelaySeconds\": ",
            vm.toString(uint256(CRITICAL_DELAY)),
            ",\n"
        );
        out = string.concat(
            out,
            "  \"adminGuardianRoleId\": ",
            vm.toString(uint256(ADMIN_ROLE_GUARDIAN_ROLE)),
            ",\n",
            "  \"operationalGuardianRoleId\": ",
            vm.toString(uint256(OPERATIONAL_ROLE_GUARDIAN_ROLE)),
            ",\n",
            "  \"profiles\": {\n",
            _profileEntry("MainAdmin", _getProfile__MainAdmin()),
            ",\n",
            _profileEntry("SecondaryAdmin", _getProfile__SecondaryAdmin()),
            ",\n",
            _profileEntry("WithdrawalPolicyManager", _getProfile__WithdrawalPolicyManager()),
            ",\n",
            _profileEntry("Rebalancer", _getProfile__Rebalancer()),
            ",\n",
            _profileEntry("Disabler", _getProfile__Disabler()),
            ",\n"
        );
        out = string.concat(
            out,
            _profileEntry("ATokenVaultRewardClaimer", _getProfile__ATokenVaultRewardClaimer()),
            ",\n",
            _profileEntry("CoverageGuardian", _getProfile__CoverageGuardian()),
            ",\n",
            _profileEntry("Funder", _getProfile__Funder()),
            ",\n",
            _profileEntry("StableVaultManager", _getProfile__StableVaultManager()),
            "\n  },\n",
            "  \"roles\": [\n",
            rolesBody,
            "  ]\n",
            "}\n"
        );

        string memory outPath = string.concat("script/output/roles.dump.", env, ".json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(outPath, out);
        console.log("Wrote %s entries to %s", roles.length, outPath);
    }

    function _profileEntry(string memory name, address addr) internal pure returns (string memory) {
        return string.concat("    \"", name, "\": \"", vm.toString(addr), "\"");
    }

    /// @dev `roleId` is emitted as a string because it is a `uint64` and JavaScript `Number` can lose precision above
    /// 2^53. Downstream JSON parsers must keep it opaque.
    function _roleEntry(uint256 index, Role memory r) internal pure returns (string memory) {
        return string.concat(
            "    {",
            "\"index\": ",
            _u(index),
            ", \"roleId\": \"",
            _u(uint256(r.roleId)),
            "\", \"selector\": \"",
            _selectorHex(r.selector),
            "\", \"delaySeconds\": ",
            _u(uint256(r.delay)),
            ", \"guardianRoleId\": ",
            _u(uint256(r.guardianRoleId)),
            ", \"criticalRisk\": ",
            r.hasCriticalRisk ? "true" : "false",
            "}"
        );
    }

    function _u(uint256 v) internal pure returns (string memory s) {
        if (v == 0) {
            return "0";
        }
        uint256 n = v;
        uint256 digits;
        while (n != 0) {
            digits++;
            n /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits--;
            buf[digits] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        s = string(buf);
    }

    function _selectorHex(bytes4 sel) internal pure returns (string memory) {
        bytes memory chars = "0123456789abcdef";
        bytes memory out = new bytes(10);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < 4; i++) {
            uint8 b = uint8(sel[i]);
            out[2 + i * 2] = chars[b >> 4];
            out[3 + i * 2] = chars[b & 0x0f];
        }
        return string(out);
    }
}
