// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {RolesConfig} from "script/base/RolesConfig.sol";

/// @title ProfilesConfig
/// @author Aave Labs
/// @notice Single source of truth for which AccessManager roles make up each operator profile.
///         (MainAdmin / SecondaryAdmin are intentionally absent — they receive the full `getAllFunctionBasedRoles`
///         bundle rather than a fixed role set.)
abstract contract ProfilesConfig is RolesConfig {
    function getProfileRoles__WithdrawalPolicyManager() internal pure returns (Role[] memory roles) {
        roles = new Role[](2);
        roles[0] = getRole__setDefaultFeeBps();
        roles[1] = getRole__setAssetFeeBps();
    }

    function getProfileRoles__Rebalancer() internal pure returns (Role[] memory roles) {
        roles = new Role[](5);
        // Allocator
        roles[0] = getRole__rebalance();
        roles[1] = getRole__setWithdrawalQueue();
        roles[2] = getRole__disableDepositsToStrategy();
        // Cross-chain push. The first is only used on the Accounting Chain (FundsHandler) and the second only on
        // the Earning Chain (EarningChainGateway), but both are granted in both chain setups so a single profile
        // config can run either side.
        roles[3] = getRole__pushFundsToChain();
        roles[4] = getRole__pushFundsToAccountingChain();
    }

    function getProfileRoles__Disabler() internal pure returns (Role[] memory roles) {
        roles = new Role[](22);
        // Allocator (defensive)
        roles[0] = getRole__rebalance();
        roles[1] = getRole__removeStrategy();
        roles[2] = getRole__disableDepositsToStrategy();
        roles[3] = getRole__distrustStrategy();
        // AssetRegistry (defensive)
        roles[4] = getRole__disableAllocatorDeposits();
        roles[5] = getRole__disableUserDeposits();
        roles[6] = getRole__disableSwapInput();
        roles[7] = getRole__disableSwapOutput();
        roles[8] = getRole__distrustAsset();
        // Gateway
        roles[9] = getRole__removeFundsBridgeAdapter();
        // WithdrawalExecutionPolicy
        roles[10] = getRole__removeSigner();
        // SlippageCoverageVault
        roles[11] = getRole__lowerPullCapPerTx();
        roles[12] = getRole__lowerWindowCap();
        roles[13] = getRole__raiseWindowSeconds();
        // DepositPolicy is Accounting Chain-only, but granted in both chain setups.
        roles[14] = getRole__lowerDepositCapacity();
        roles[15] = getRole__lowerDepositRefillRate();
        roles[16] = getRole__lowerGlobalDepositCapacity();
        roles[17] = getRole__lowerGlobalDepositRefillRate();
        // FundsBridgingPolicy
        roles[18] = getRole__lowerBridgingCapacity();
        roles[19] = getRole__lowerBridgingRefillRate();
        roles[20] = getRole__lowerGlobalBridgingCapacity();
        roles[21] = getRole__lowerGlobalBridgingRefillRate();
    }

    function getProfileRoles__ATokenVaultRewardClaimer() internal pure returns (Role[] memory roles) {
        roles = new Role[](2);
        roles[0] = getRole__claimMerklRewards();
        roles[1] = getRole__emergencyRescue();
    }

    function getProfileRoles__Funder() internal pure returns (Role[] memory roles) {
        roles = new Role[](2);
        roles[0] = getRole__topUp();
        roles[1] = getRole__fundCoverage();
    }

    function getProfileRoles__Rescuer() internal pure returns (Role[] memory roles) {
        roles = new Role[](2);
        roles[0] = getRole__rescueTokens();
        roles[1] = getRole__rescueNative();
    }

    function getProfileRoles__StableVaultManager() internal view returns (Role[] memory roles) {
        roles = new Role[](4);
        roles[0] = getRole__setUserRate();
        roles[1] = getRole__setSubVaultRate();
        roles[2] = getRole__setDefaultSubVault();
        roles[3] = getRole__claimSurplusInterest();
    }
}
