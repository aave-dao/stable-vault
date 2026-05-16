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

    /// @dev Pre-flight validator for the redemption-limit config block under `configPrefix` (e.g.
    /// `.accountingChain.withdrawalExecutionPolicy`). Asserts:
    ///   - both floors are in `(0, uint128.max]`,
    ///   - seed capacity is strictly greater than the floor AND strictly less than `uint128.max`. The latter is
    ///     `RateLimitBucketLib.UNLIMITED_CAPACITY`; if the bucket were ever raised into that state during the
    ///     bootstrap window (`refillRate == 0`, before `_initRedemptionLimit` runs), the rate-limit would be
    ///     silently disabled and the always-exit floor would no longer be load-bearing. The contract itself may
    ///     not reject this sentinel, so this pre-flight is the deploy-time guard.
    ///   - seed refill rate is strictly greater than the floor and fits in `uint128`.
    /// Run this before any deploy side effect — a misconfig must not burn the deterministic CREATE3 address
    /// namespace.
    function _validateRedemptionLimitConfig(string memory configPrefix) internal view {
        uint256 minCap = vm.parseUint(_configString(string.concat(configPrefix, ".minRedemptionCapacity")));
        require(minCap > 0 && minCap <= type(uint128).max, "minRedemptionCapacity: must be in (0, uint128.max]");

        uint256 minRefill = vm.parseUint(_configString(string.concat(configPrefix, ".minRedemptionRefillRate")));
        require(minRefill > 0 && minRefill <= type(uint128).max, "minRedemptionRefillRate: must be in (0, uint128.max]");

        uint256 seedCap = vm.parseUint(_configString(string.concat(configPrefix, ".redemptionLimit.capacity")));
        require(
            seedCap < type(uint128).max, "redemptionLimit.capacity: must be < uint128.max (UNLIMITED_CAPACITY sentinel)"
        );
        require(seedCap > minCap, "redemptionLimit.capacity: must exceed minRedemptionCapacity");

        uint256 seedRefill = vm.parseUint(_configString(string.concat(configPrefix, ".redemptionLimit.refillRate")));
        require(seedRefill <= type(uint128).max, "redemptionLimit.refillRate: exceeds uint128");
        require(seedRefill > minRefill, "redemptionLimit.refillRate: must exceed minRedemptionRefillRate");
    }
}
