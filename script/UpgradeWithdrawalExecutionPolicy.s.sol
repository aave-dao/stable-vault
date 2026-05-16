// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {DeploymentConfig} from "script/base/DeploymentConfig.sol";
import {Upgrade} from "script/base/Upgrade.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";

contract UpgradeWithdrawalExecutionPolicy is Create3AddressBook, Upgrade, DeploymentConfig {
    using Strings for address;

    address WITHDRAWAL_EXECUTION_POLICY_PROXY;
    address DEPLOYER = 0xBB700dA5CCC9Ec5605780Fc40695f1206B090303;

    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.staging.json";
    }

    function run() public {
        WITHDRAWAL_EXECUTION_POLICY_PROXY = getWithdrawalExecutionPolicyAddress(DEPLOYER);

        vm.startBroadcast(DEPLOYER);
        _upgrade();
        vm.stopBroadcast();
    }

    function _upgrade() internal {
        WithdrawalExecutionPolicy policy = WithdrawalExecutionPolicy(WITHDRAWAL_EXECUTION_POLICY_PROXY);

        uint128 newMinCapacity =
            uint128(vm.parseUint(_configString(".accountingChain.withdrawalExecutionPolicy.minRedemptionCapacity")));
        uint128 newMinRefillRate =
            uint128(vm.parseUint(_configString(".accountingChain.withdrawalExecutionPolicy.minRedemptionRefillRate")));

        // Floors are baked into impl bytecode. The new impl must not weaken either floor, otherwise the
        // always-exit invariant is silently degraded post-upgrade.
        require(newMinCapacity >= policy.getMinRedemptionCapacity(), "Upgrade weakens MIN_REDEMPTION_CAPACITY");
        require(newMinRefillRate >= policy.getMinRedemptionRefillRate(), "Upgrade weakens MIN_REDEMPTION_REFILL_RATE");

        address implementation =
            address(new WithdrawalExecutionPolicy(getStableVaultAddress(DEPLOYER), newMinCapacity, newMinRefillRate));
        _logDeployment("WithdrawalExecutionPolicy::Implementation", "", implementation);

        address proxyAdmin = _getAdminFromSlot(WITHDRAWAL_EXECUTION_POLICY_PROXY);
        ProxyAdmin(proxyAdmin)
            .upgradeAndCall(ITransparentUpgradeableProxy(WITHDRAWAL_EXECUTION_POLICY_PROXY), implementation, "");

        // Proxy storage survives the upgrade. Confirm the already-seeded bucket still has headroom above the new
        // floors: at-floor would leave operators no room for `lower*` during incident response, matching the strict
        // assertion in `_assertRequiredPoliciesSet` at deploy time.
        RateLimitBucketLib.Bucket memory bucket = policy.getRedemptionBucket();
        require(bucket.capacity > newMinCapacity, "Post-upgrade: bucket capacity at or below new floor");
        require(bucket.refillRate > newMinRefillRate, "Post-upgrade: bucket refill rate at or below new floor");
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/accounting.json", string.concat(".", name));
    }
}
