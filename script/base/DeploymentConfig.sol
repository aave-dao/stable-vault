// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {MathLib} from "src/libraries/MathLib.sol";

abstract contract DeploymentConfig is Script {
    error ConfigUintTooLarge(string key, uint256 value, uint256 max);

    function _configPath() internal view virtual returns (string memory);

    function _readConfig() internal view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return _stripJsonComments(vm.readFile(_configPath()));
    }

    function _configAddress(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(_readConfig(), key);
    }

    function _configUint(string memory key) internal view returns (uint256) {
        string memory config = _readConfig();
        try vm.parseJsonUint(config, key) returns (uint256 value) {
            return value;
        } catch {
            return vm.parseUint(vm.parseJsonString(config, key));
        }
    }

    function _configUint8(string memory key) internal view returns (uint8) {
        return uint8(_configUintMax(key, type(uint8).max));
    }

    function _configUint16(string memory key) internal view returns (uint16) {
        return uint16(_configUintMax(key, type(uint16).max));
    }

    function _configUint32(string memory key) internal view returns (uint32) {
        return uint32(_configUintMax(key, type(uint32).max));
    }

    function _configUint64(string memory key) internal view returns (uint64) {
        return uint64(_configUintMax(key, type(uint64).max));
    }

    function _configUint128(string memory key) internal view returns (uint128) {
        return uint128(_configUintMax(key, type(uint128).max));
    }

    function _configString(string memory key) internal view returns (string memory) {
        return vm.parseJsonString(_readConfig(), key);
    }

    function _configBool(string memory key) internal view returns (bool) {
        return vm.parseJsonBool(_readConfig(), key);
    }

    function _configUintMax(string memory key, uint256 max) private view returns (uint256) {
        uint256 value = _configUint(key);
        if (value > max) {
            revert ConfigUintTooLarge(key, value, max);
        }
        return value;
    }

    function _stripJsonComments(string memory input) internal pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        bytes memory outputBytes = new bytes(inputBytes.length);
        uint256 outputLength;
        bool inString;
        bool escaped;

        for (uint256 i = 0; i < inputBytes.length; i++) {
            bytes1 char = inputBytes[i];

            if (inString) {
                outputBytes[outputLength++] = char;

                if (escaped) {
                    escaped = false;
                } else if (char == "\\") {
                    escaped = true;
                } else if (char == '"') {
                    inString = false;
                }
                continue;
            }

            if (char == '"') {
                inString = true;
                outputBytes[outputLength++] = char;
                continue;
            }

            if (char == "/" && i + 1 < inputBytes.length) {
                bytes1 nextChar = inputBytes[i + 1];
                if (nextChar == "/") {
                    i += 2;
                    while (i < inputBytes.length && inputBytes[i] != "\n" && inputBytes[i] != "\r") {
                        i++;
                    }
                    if (i < inputBytes.length) {
                        outputBytes[outputLength++] = inputBytes[i];
                    }
                    continue;
                }
                if (nextChar == "*") {
                    i += 2;
                    while (i + 1 < inputBytes.length && !(inputBytes[i] == "*" && inputBytes[i + 1] == "/")) {
                        if (inputBytes[i] == "\n" || inputBytes[i] == "\r") {
                            outputBytes[outputLength++] = inputBytes[i];
                        }
                        i++;
                    }
                    i++;
                    continue;
                }
            }

            outputBytes[outputLength++] = char;
        }

        bytes memory stripped = new bytes(outputLength);
        for (uint256 i = 0; i < outputLength; i++) {
            stripped[i] = outputBytes[i];
        }
        return string(stripped);
    }

    function _validateCommonDeploymentParameters() internal view {
        require(_configUint8(".maxStrategiesPerAsset") > 0, "maxStrategiesPerAsset must be > 0");
        require(_configUint(".chainlinkPriceOracleHeartbeat") > 0, "chainlinkPriceOracleHeartbeat must be > 0");

        uint256 minValidPriceRay = _configUint(".priceOracleMinValidPriceRay");
        require(
            minValidPriceRay > 0 && minValidPriceRay <= MathLib.RAY, "priceOracleMinValidPriceRay must be in (0, RAY]"
        );
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
        uint128 minCap = _configUint128(string.concat(configPrefix, ".minRedemptionCapacity"));
        require(minCap > 0, "minRedemptionCapacity: must be in (0, uint128.max]");

        uint128 minRefill = _configUint128(string.concat(configPrefix, ".minRedemptionRefillRate"));
        require(minRefill > 0, "minRedemptionRefillRate: must be in (0, uint128.max]");

        uint128 seedCap = _configUint128(string.concat(configPrefix, ".redemptionLimit.capacity"));
        require(
            seedCap < type(uint128).max, "redemptionLimit.capacity: must be < uint128.max (UNLIMITED_CAPACITY sentinel)"
        );
        require(seedCap > minCap, "redemptionLimit.capacity: must exceed minRedemptionCapacity");

        uint128 seedRefill = _configUint128(string.concat(configPrefix, ".redemptionLimit.refillRate"));
        require(seedRefill > minRefill, "redemptionLimit.refillRate: must exceed minRedemptionRefillRate");
    }
}
