// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Va359ClaimSurplusInterest} from "script/migrate/preprod/Va359ClaimSurplusInterest.s.sol";

/// @title VA-359 claimSurplusInterest re-config — STAGING concrete.
/// @notice Same logic as the preprod VA-359 (guardian/admin → operational(2), grant + execution delays → 0),
///         pointed at the staging config. Verified gap: staging claimSurplusInterest guardian/admin = 1/1,
///         prod = 2/2.
contract Va359ClaimSurplusInterestStaging is Va359ClaimSurplusInterest {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.staging.jsonc";
    }
}
