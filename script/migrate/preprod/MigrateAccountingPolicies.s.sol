// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {PolicyMigrationBase} from "script/migrate/preprod/PolicyMigrationBase.sol";

/// @title  Preprod policy migration — ACCOUNTING chain (Arbitrum).
/// @notice DepositPolicy + FundsBridgingPolicy + WithdrawalExecutionPolicy. Run each step separately:
///   forge script MigrateAccountingPolicies --sig "stepDeploy()"                       --sender <DEPLOYER>
///   forge script MigrateAccountingPolicies --sig "verify()"
///   forge script MigrateAccountingPolicies --sig "stepScheduleWiring()"               --sender <MAIN_ADMIN>
///   (wait 2h)
///   forge script MigrateAccountingPolicies --sig "stepExecuteWiringScheduleBuckets()" --sender <MAIN_ADMIN>
///   (wait 1h)
///   forge script MigrateAccountingPolicies --sig "stepExecuteBuckets()"               --sender <MAIN_ADMIN>
///   forge script MigrateAccountingPolicies --sig "verify()"
///
/// Inherits only PolicyMigrationBase (no chain-deploy base) to avoid the BaseChainDeployment diamond;
/// the chain hooks below mirror AccountingChainDeployment. Policy ids use the same documented keccak
/// preimages as the source constants (verified equal to AccountingChainDeployment's literals).
contract MigrateAccountingPolicies is PolicyMigrationBase {
    function _configPath() internal pure virtual override returns (string memory) {
        return "config/deployment-config.preprod.jsonc";
    }

    // --- BaseChainDeployment chain hooks (accounting = Arbitrum) ---
    function _chainConfigPrefix() internal pure override returns (string memory) {
        return ".accountingChain";
    }

    function _remoteChainConfigPrefix() internal pure override returns (string memory) {
        return ".earningChain";
    }

    function _bridgePolicyId() internal pure override returns (bytes32) {
        return keccak256("aave.stable-vault.FundsHandler.policy.bridge");
    }

    function _withdrawalExecutionPolicyId() internal pure override returns (bytes32) {
        return keccak256("aave.stable-vault.StableVault.policy.withdrawal-execution");
    }

    function _withdrawalExecutionPolicyTarget() internal view override returns (address) {
        return getStableVaultAddress(_deployer());
    }

    function _fundsBridgingPolicyHolder() internal view override returns (address) {
        return getFundsHandlerAddress(_deployer());
    }

    // --- PolicyMigrationBase hooks ---
    function _hasDepositPolicy() internal pure override returns (bool) {
        return true;
    }

    function _depositPolicyId() internal pure override returns (bytes32) {
        return keccak256("aave.stable-vault.StableVault.policy.deposit");
    }

    function _depositPolicyApplier() internal view override returns (address) {
        return getStableVaultAddress(_deployer());
    }
}
