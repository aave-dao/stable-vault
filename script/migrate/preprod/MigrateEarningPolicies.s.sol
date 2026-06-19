// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {PolicyMigrationBase} from "script/migrate/preprod/PolicyMigrationBase.sol";

/// @title  Preprod policy migration — EARNING chain (Ethereum).
/// @notice FundsBridgingPolicy + WithdrawalExecutionPolicy only (no DepositPolicy on the earning chain).
///         Appliers are the EarningChainGateway; policy ids are the earning-chain ids. Same step sequence
///         as the accounting script:
///   forge script MigrateEarningPolicies --sig "stepDeploy()"                       --sender <DEPLOYER>
///   forge script MigrateEarningPolicies --sig "verify()"
///   forge script MigrateEarningPolicies --sig "stepScheduleWiring()"               --sender <MAIN_ADMIN>
///   (wait 2h)
///   forge script MigrateEarningPolicies --sig "stepExecuteWiringScheduleBuckets()" --sender <MAIN_ADMIN>
///   (wait 1h)
///   forge script MigrateEarningPolicies --sig "stepExecuteBuckets()"               --sender <MAIN_ADMIN>
///   forge script MigrateEarningPolicies --sig "verify()"
///
/// Inherits only PolicyMigrationBase; the chain hooks below mirror EarningChainDeployment.
contract MigrateEarningPolicies is PolicyMigrationBase {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.preprod.jsonc";
    }

    // --- BaseChainDeployment chain hooks (earning = Ethereum) ---
    function _chainConfigPrefix() internal pure override returns (string memory) {
        return ".earningChain";
    }

    function _remoteChainConfigPrefix() internal pure override returns (string memory) {
        return ".accountingChain";
    }

    function _bridgePolicyId() internal pure override returns (bytes32) {
        return keccak256("aave.stable-vault.EarningChainGateway.policy.bridge");
    }

    function _withdrawalExecutionPolicyId() internal pure override returns (bytes32) {
        return keccak256("aave.stable-vault.EarningChainGateway.policy.withdrawal-execution");
    }

    function _withdrawalExecutionPolicyTarget() internal view override returns (address) {
        return getGatewayAddress(_deployer());
    }

    function _fundsBridgingPolicyHolder() internal view override returns (address) {
        return getGatewayAddress(_deployer());
    }

    // --- PolicyMigrationBase hooks (no DepositPolicy on the earning chain) ---
    function _hasDepositPolicy() internal pure override returns (bool) {
        return false;
    }

    function _depositPolicyId() internal pure override returns (bytes32) {
        return bytes32(0);
    }

    function _depositPolicyApplier() internal view override returns (address) {
        return address(0);
    }
}
