// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {MigrateAccountingPolicies} from "script/migrate/preprod/MigrateAccountingPolicies.s.sol";
import {MigrateEarningPolicies} from "script/migrate/preprod/MigrateEarningPolicies.s.sol";

/// @title Staging policy migration (VA-347) — STAGING concretes.
/// @notice Identical logic to the preprod policy migration (reuses the preprod concretes wholesale), with
///         two staging-specific overrides:
///           - `_configPath` → the staging deployment config (drives addresses, caps, fee, signer).
///           - `_cutoverLast` → true: the PolicyRegistry `setPolicy` cutover EXECUTES last, after the new
///             policy has capacity + signer, so the registry is never pointed at a zero-capacity policy →
///             NO deposit/withdrawal/bridging downtime (the prod-ready, non-blocking ordering).
///         Staging rate-limit caps intentionally differ from prod (kept as the staging config sets them).
contract MigrateAccountingPoliciesStaging is MigrateAccountingPolicies {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.staging.jsonc";
    }

    function _cutoverLast() internal pure override returns (bool) {
        return true;
    }
}

contract MigrateEarningPoliciesStaging is MigrateEarningPolicies {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.staging.jsonc";
    }

    function _cutoverLast() internal pure override returns (bool) {
        return true;
    }
}
