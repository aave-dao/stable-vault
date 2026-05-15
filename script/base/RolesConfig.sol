// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {DeploymentConfig} from "script/base/DeploymentConfig.sol";

import {IATokenVault} from "lib/aave-vault/src/interfaces/IATokenVault.sol";
import {IATokenVaultMerklRewardClaimer} from "lib/aave-vault/src/interfaces/IATokenVaultMerklRewardClaimer.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {ISlippageCoverageVault} from "src/interfaces/ISlippageCoverageVault.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";
import {FundsBridgingPolicy} from "src/policies/FundsBridgingPolicy.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";

abstract contract RolesConfig is DeploymentConfig {
    uint32 internal constant NO_DELAY = 0;
    uint32 internal immutable LOW_DELAY = uint32(_configUint(".lowDelay"));
    uint32 internal immutable MEDIUM_DELAY = uint32(_configUint(".mediumDelay"));
    uint32 internal immutable HIGH_DELAY = uint32(_configUint(".highDelay"));
    uint32 internal immutable CRITICAL_DELAY = uint32(_configUint(".criticalDelay"));

    // Special roles not associated with an specific selector
    uint64 constant ADMIN_ROLE = uint64(0);
    uint64 constant ADMIN_ROLE_GUARDIAN_ROLE = uint64(1);
    uint64 constant OPERATIONAL_ROLE_GUARDIAN_ROLE = uint64(2);

    struct Role {
        uint64 roleId;
        bytes4 selector;
        uint32 delay;
        uint64 guardianRoleId;
        bool hasCriticalRisk;
    }

    /// @custom:delay High
    /// @custom:location AssetRegistry
    function getRole__setAssetConfig() internal view returns (Role memory) {
        bytes4 selector = IAssetRegistry.setAssetConfig.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location AssetRegistry
    function getRole__disableAllocatorDeposits() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.disableAllocatorDeposits.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location AssetRegistry
    function getRole__disableSwapInput() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.disableSwapInput.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location AssetRegistry
    function getRole__disableSwapOutput() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.disableSwapOutput.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location AssetRegistry
    function getRole__disableUserDeposits() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.disableUserDeposits.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location AssetRegistry
    function getRole__enableAllocatorDeposits() internal view returns (Role memory) {
        bytes4 selector = IAssetRegistry.enableAllocatorDeposits.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location AssetRegistry
    function getRole__enableSwapInput() internal view returns (Role memory) {
        bytes4 selector = IAssetRegistry.enableSwapInput.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location AssetRegistry
    function getRole__enableSwapOutput() internal view returns (Role memory) {
        bytes4 selector = IAssetRegistry.enableSwapOutput.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location AssetRegistry
    function getRole__enableUserDeposits() internal view returns (Role memory) {
        bytes4 selector = IAssetRegistry.enableUserDeposits.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location AssetRegistry
    function getRole__trustAsset() internal view returns (Role memory) {
        bytes4 selector = IAssetRegistry.trustAsset.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location AssetRegistry
    function getRole__distrustAsset() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.distrustAsset.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location EarningChainGateway, AccountingChainGateway
    function getRole__addBridgeAdapter() internal view returns (Role memory) {
        bytes4 selector = IChainGateway.addBridgeAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location EarningChainGateway, AccountingChainGateway
    function getRole__removeBridgeAdapter() internal pure returns (Role memory) {
        bytes4 selector = IChainGateway.removeBridgeAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location WithdrawalExecutionPolicy
    function getRole__setAssetFeeBps() internal pure returns (Role memory) {
        bytes4 selector = WithdrawalExecutionPolicy.setAssetFeeBps.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location WithdrawalExecutionPolicy
    function getRole__setDefaultFeeBps() internal pure returns (Role memory) {
        bytes4 selector = WithdrawalExecutionPolicy.setDefaultFeeBps.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location WithdrawalExecutionPolicy
    function getRole__addSigner() internal view returns (Role memory) {
        bytes4 selector = WithdrawalExecutionPolicy.addSigner.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location WithdrawalExecutionPolicy
    function getRole__removeSigner() internal pure returns (Role memory) {
        bytes4 selector = WithdrawalExecutionPolicy.removeSigner.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location CcipAdapter
    function getRole__setDestinationChainAdapter() internal view returns (Role memory) {
        bytes4 selector = IBridgeAdapter.setDestinationChainAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location StableVault
    function getRole__setUserRate() internal pure returns (Role memory) {
        bytes4 selector = IStableVault.setUserRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Low
    /// @custom:location StableVault
    function getRole__setSubVaultRate() internal view returns (Role memory) {
        bytes4 selector = IStableVault.setSubVaultRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: LOW_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location StableVault
    function getRole__setDefaultSubVault() internal view returns (Role memory) {
        bytes4 selector = IStableVault.setDefaultSubVault.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MEDIUM_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location StableVault
    function getRole__claimSurplusInterest() internal view returns (Role memory) {
        bytes4 selector = IStableVault.claimSurplusInterest.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location StableVault
    function getRole__setTreasury() internal view returns (Role memory) {
        bytes4 selector = IStableVault.setTreasury.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location CcipAdapter
    function getRole__setChainSelector() internal view returns (Role memory) {
        bytes4 selector = ICcipBridgeAdapter.setChainSelector.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location CcipAdapter
    function getRole__replayFundsReceiving() internal pure returns (Role memory) {
        bytes4 selector = ICcipBridgeAdapter.replayFundsReceiving.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location Allocator
    function getRole__rebalance() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.rebalance.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location Allocator
    function getRole__topUp() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.topUp.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location Allocator
    function getRole__addStrategy() internal view returns (Role memory) {
        bytes4 selector = IAllocator.addStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location Allocator
    function getRole__removeStrategy() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.removeStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location Allocator
    function getRole__disableDepositsToStrategy() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.disableDepositsToStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location Allocator
    function getRole__setDefaultStrategy() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.setDefaultStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location Allocator
    function getRole__enableDepositsToStrategy() internal view returns (Role memory) {
        bytes4 selector = IAllocator.enableDepositsToStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location Allocator
    function getRole__trustStrategy() internal view returns (Role memory) {
        bytes4 selector = IAllocator.trustStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location Allocator
    function getRole__distrustStrategy() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.distrustStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location FundsHandler, EarningChainGateway, StableVault, AccountingChainGateway
    function getRole__rescueTokens() internal pure returns (Role memory) {
        bytes4 selector = IRescuableToken.rescueTokens.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location CcipAdapter, StableVault, AccountingChainGateway, FundsHandler, EarningChainGateway
    function getRole__rescueNative() internal pure returns (Role memory) {
        bytes4 selector = IRescuableNative.rescueNative.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location FundsHandler
    function getRole__pushFundsToChain() internal pure returns (Role memory) {
        bytes4 selector = IFundsHandler.pushFundsToChain.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location FundsHandler
    function getRole__addEarningChain() internal view returns (Role memory) {
        bytes4 selector = IFundsHandler.addEarningChain.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location FundsHandler
    function getRole__removeEarningChain() internal view returns (Role memory) {
        bytes4 selector = IFundsHandler.removeEarningChain.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location EarningChainGateway
    function getRole__pushFundsToAccountingChain() internal pure returns (Role memory) {
        bytes4 selector = IEarningChainGateway.pushFundsToAccountingChain.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location ChainBalanceOracle
    function getRole__setChainBalanceOracleAdapter() internal view returns (Role memory) {
        bytes4 selector = ChainBalanceOracle.setChainBalanceOracleAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location PriceOracle
    function getRole__setOracleAdapterForAsset() internal view returns (Role memory) {
        bytes4 selector = PriceOracle.setOracleAdapterForAsset.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Critical
    /// @custom:location PolicyRegistry
    function getRole__setPolicy() internal view returns (Role memory) {
        bytes4 selector = IPolicyRegistry.setPolicy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location DepositPolicy
    function getRole__raiseDepositCapacity() internal view returns (Role memory) {
        bytes4 selector = DepositPolicy.raiseDepositCapacity.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location DepositPolicy
    function getRole__raiseDepositRefillRate() internal view returns (Role memory) {
        bytes4 selector = DepositPolicy.raiseDepositRefillRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location DepositPolicy
    function getRole__lowerDepositCapacity() internal pure returns (Role memory) {
        bytes4 selector = DepositPolicy.lowerDepositCapacity.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location DepositPolicy
    function getRole__lowerDepositRefillRate() internal pure returns (Role memory) {
        bytes4 selector = DepositPolicy.lowerDepositRefillRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location FundsBridgingPolicy
    function getRole__raiseBridgingCapacity() internal view returns (Role memory) {
        bytes4 selector = FundsBridgingPolicy.raiseBridgingCapacity.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location FundsBridgingPolicy
    function getRole__raiseBridgingRefillRate() internal view returns (Role memory) {
        bytes4 selector = FundsBridgingPolicy.raiseBridgingRefillRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location FundsBridgingPolicy
    function getRole__lowerBridgingCapacity() internal pure returns (Role memory) {
        bytes4 selector = FundsBridgingPolicy.lowerBridgingCapacity.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location FundsBridgingPolicy
    function getRole__lowerBridgingRefillRate() internal pure returns (Role memory) {
        bytes4 selector = FundsBridgingPolicy.lowerBridgingRefillRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location WithdrawalExecutionPolicy
    function getRole__raiseRedemptionCapacity() internal view returns (Role memory) {
        bytes4 selector = WithdrawalExecutionPolicy.raiseRedemptionCapacity.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location WithdrawalExecutionPolicy
    function getRole__raiseRedemptionRefillRate() internal view returns (Role memory) {
        bytes4 selector = WithdrawalExecutionPolicy.raiseRedemptionRefillRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location WithdrawalExecutionPolicy
    function getRole__lowerRedemptionCapacity() internal pure returns (Role memory) {
        bytes4 selector = WithdrawalExecutionPolicy.lowerRedemptionCapacity.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location WithdrawalExecutionPolicy
    function getRole__lowerRedemptionRefillRate() internal pure returns (Role memory) {
        bytes4 selector = WithdrawalExecutionPolicy.lowerRedemptionRefillRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location aToken Vault
    function getRole__claimMerklRewards() internal pure returns (Role memory) {
        bytes4 selector = IATokenVaultMerklRewardClaimer.claimMerklRewards.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location aToken Vault
    function getRole__emergencyRescue() internal pure returns (Role memory) {
        bytes4 selector = IATokenVault.emergencyRescue.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__enableOverrideMode() internal pure returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.enableOverrideMode.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__disableOverrideMode() internal pure returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.disableOverrideMode.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location SlippageCoverageVault
    function getRole__raisePullCapPerTx() internal view returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.raisePullCapPerTx.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__lowerPullCapPerTx() internal pure returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.lowerPullCapPerTx.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location SlippageCoverageVault
    function getRole__raiseWindowCap() internal view returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.raiseWindowCap.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__lowerWindowCap() internal pure returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.lowerWindowCap.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__raiseWindowSeconds() internal pure returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.raiseWindowSeconds.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location SlippageCoverageVault
    function getRole__lowerWindowSeconds() internal view returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.lowerWindowSeconds.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location SlippageCoverageVault
    function getRole__setMaxSlippageBps() internal view returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.setMaxSlippageBps.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location SlippageCoverageVault
    function getRole__setOverrideMaxSlippageBps() internal view returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.setOverrideMaxSlippageBps.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__fundCoverage() internal pure returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.fundCoverage.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location SlippageCoverageVault
    function getRole__sweepSlippageCoverageVault() internal view returns (Role memory) {
        bytes4 selector = ISlippageCoverageVault.sweep.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    function getAllFunctionBasedRoles() internal view returns (Role[] memory) {
        Role[] memory roles = new Role[](69);

        // AssetRegistry
        roles[0] = getRole__setAssetConfig();
        roles[1] = getRole__disableAllocatorDeposits();
        roles[2] = getRole__disableSwapInput();
        roles[3] = getRole__disableSwapOutput();
        roles[4] = getRole__disableUserDeposits();
        roles[5] = getRole__enableAllocatorDeposits();
        roles[6] = getRole__enableSwapInput();
        roles[7] = getRole__enableSwapOutput();
        roles[8] = getRole__enableUserDeposits();
        roles[9] = getRole__trustAsset();
        roles[10] = getRole__distrustAsset();

        // Gateway
        roles[11] = getRole__addBridgeAdapter();
        roles[12] = getRole__removeBridgeAdapter();

        // WithdrawalExecutionPolicy
        roles[13] = getRole__setAssetFeeBps();
        roles[14] = getRole__setDefaultFeeBps();
        roles[15] = getRole__addSigner();
        roles[16] = getRole__removeSigner();

        // BridgeAdapter
        roles[17] = getRole__setDestinationChainAdapter();
        roles[18] = getRole__setChainSelector();
        roles[19] = getRole__replayFundsReceiving();

        // StableVault
        roles[20] = getRole__setUserRate();
        roles[21] = getRole__setSubVaultRate();
        roles[22] = getRole__setDefaultSubVault();
        roles[23] = getRole__claimSurplusInterest();
        roles[24] = getRole__setTreasury();

        // Allocator
        roles[25] = getRole__rebalance();
        roles[26] = getRole__addStrategy();
        roles[27] = getRole__removeStrategy();
        roles[28] = getRole__disableDepositsToStrategy();
        roles[29] = getRole__setDefaultStrategy();
        roles[30] = getRole__enableDepositsToStrategy();
        roles[31] = getRole__topUp();
        roles[32] = getRole__trustStrategy();
        roles[33] = getRole__distrustStrategy();

        // Rescue
        roles[34] = getRole__rescueTokens();
        roles[35] = getRole__rescueNative();

        // FundsHandler / EarningChainGateway
        roles[36] = getRole__pushFundsToChain();
        roles[37] = getRole__pushFundsToAccountingChain();
        roles[38] = getRole__addEarningChain();
        roles[39] = getRole__removeEarningChain();

        // Oracles
        roles[40] = getRole__setChainBalanceOracleAdapter();
        roles[41] = getRole__setOracleAdapterForAsset();

        // External - aToken Vault
        roles[42] = getRole__claimMerklRewards();
        roles[43] = getRole__emergencyRescue();

        // SlippageCoverageVault
        roles[44] = getRole__enableOverrideMode();
        roles[45] = getRole__disableOverrideMode();
        roles[46] = getRole__raisePullCapPerTx();
        roles[47] = getRole__lowerPullCapPerTx();
        roles[48] = getRole__raiseWindowCap();
        roles[49] = getRole__lowerWindowCap();
        roles[50] = getRole__raiseWindowSeconds();
        roles[51] = getRole__lowerWindowSeconds();
        roles[52] = getRole__setMaxSlippageBps();
        roles[53] = getRole__setOverrideMaxSlippageBps();
        roles[54] = getRole__fundCoverage();
        roles[55] = getRole__sweepSlippageCoverageVault();

        // PolicyRegistry
        roles[56] = getRole__setPolicy();

        // DepositPolicy / FundsBridgingPolicy
        roles[57] = getRole__raiseDepositCapacity();
        roles[58] = getRole__raiseDepositRefillRate();
        roles[59] = getRole__lowerDepositCapacity();
        roles[60] = getRole__lowerDepositRefillRate();
        roles[61] = getRole__raiseBridgingCapacity();
        roles[62] = getRole__raiseBridgingRefillRate();
        roles[63] = getRole__lowerBridgingCapacity();
        roles[64] = getRole__lowerBridgingRefillRate();

        // WithdrawalExecutionPolicy redemption rate-limit
        roles[65] = getRole__raiseRedemptionCapacity();
        roles[66] = getRole__raiseRedemptionRefillRate();
        roles[67] = getRole__lowerRedemptionCapacity();
        roles[68] = getRole__lowerRedemptionRefillRate();

        return roles;
    }

    function _selectorToRoleId(bytes4 selector) internal pure returns (uint64) {
        return uint64(bytes8(abi.encodePacked(selector, bytes4(0))));
    }
}
