// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {DeploymentConfig} from "script/base/DeploymentConfig.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {ICrossChainReceiver} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainReceiver.sol";
import {IWithGuardian} from "aave-delivery-infrastructure/contracts/old-oz/interfaces/IWithGuardian.sol";
import {IRescuable} from "solidity-utils/contracts/utils/interfaces/IRescuable.sol";

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
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {SlippageCoverageVault} from "src/periphery/SlippageCoverageVault.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";
import {FundsBridgingPolicy} from "src/policies/FundsBridgingPolicy.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";

abstract contract RolesConfig is DeploymentConfig {
    struct Role {
        uint64 roleId;
        bytes4 selector;
        uint32 delay;
        uint64 guardianRoleId;
        bool hasCriticalRisk;
    }

    uint32 internal constant NO_DELAY = 0;
    uint32 internal immutable LOW_DELAY = _configUint32(".lowDelay");
    uint32 internal immutable MEDIUM_DELAY = _configUint32(".mediumDelay");
    uint32 internal immutable HIGH_DELAY = _configUint32(".highDelay");
    uint32 internal immutable CRITICAL_DELAY = _configUint32(".criticalDelay");

    // Special roles not associated with an specific selector
    uint64 constant ADMIN_ROLE = uint64(0);
    uint64 constant ADMIN_ROLE_GUARDIAN_ROLE = uint64(1);
    uint64 constant OPERATIONAL_ROLE_GUARDIAN_ROLE = uint64(2);

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
    function getRole__addFundsBridgeAdapter() internal view returns (Role memory) {
        bytes4 selector = IChainGateway.addFundsBridgeAdapter.selector;
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
    function getRole__removeFundsBridgeAdapter() internal pure returns (Role memory) {
        bytes4 selector = IChainGateway.removeFundsBridgeAdapter.selector;
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
    function getRole__addDataOnlyBridgeAdapter() internal view returns (Role memory) {
        bytes4 selector = IChainGateway.addDataOnlyBridgeAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location EarningChainGateway, AccountingChainGateway
    function getRole__initiateDataOnlyBridgeAdapterRemoval() internal view returns (Role memory) {
        bytes4 selector = IChainGateway.initiateDataOnlyBridgeAdapterRemoval.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay High
    /// @custom:location EarningChainGateway, AccountingChainGateway
    function getRole__finalizeDataOnlyBridgeAdapterRemoval() internal view returns (Role memory) {
        bytes4 selector = IChainGateway.finalizeDataOnlyBridgeAdapterRemoval.selector;
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
    /// @custom:location CcipAdapter, AdiAdapter
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

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiApproveSenders() internal view returns (Role memory) {
        bytes4 selector = ICrossChainForwarder.approveSenders.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiRemoveSenders() internal view returns (Role memory) {
        bytes4 selector = ICrossChainForwarder.removeSenders.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiEnableBridgeAdapters() internal view returns (Role memory) {
        bytes4 selector = ICrossChainForwarder.enableBridgeAdapters.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiDisableBridgeAdapters() internal view returns (Role memory) {
        bytes4 selector = ICrossChainForwarder.disableBridgeAdapters.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiUpdateOptimalBandwidthByChain() internal view returns (Role memory) {
        bytes4 selector = ICrossChainForwarder.updateOptimalBandwidthByChain.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiConfigAdapter() internal view returns (Role memory) {
        bytes4 selector = ICrossChainForwarder.configAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiUpdateRequiredForwardingSuccessesByChain() internal view returns (Role memory) {
        bytes4 selector = ICrossChainForwarder.updateRequiredForwardingSuccessesByChain.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiUpdateConfirmations() internal view returns (Role memory) {
        bytes4 selector = ICrossChainReceiver.updateConfirmations.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiUpdateMessagesValidityTimestamp() internal view returns (Role memory) {
        bytes4 selector = ICrossChainReceiver.updateMessagesValidityTimestamp.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiAllowReceiverBridgeAdapters() internal view returns (Role memory) {
        bytes4 selector = ICrossChainReceiver.allowReceiverBridgeAdapters.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiDisallowReceiverBridgeAdapters() internal view returns (Role memory) {
        bytes4 selector = ICrossChainReceiver.disallowReceiverBridgeAdapters.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiEmergencyTokenTransfer() internal view returns (Role memory) {
        bytes4 selector = IRescuable.emergencyTokenTransfer.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiEmergencyEtherTransfer() internal view returns (Role memory) {
        bytes4 selector = IRescuable.emergencyEtherTransfer.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiTransferOwnership() internal view returns (Role memory) {
        bytes4 selector = Ownable.transferOwnership.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Critical
    /// @custom:location AdiCrossChainController
    function getRole__adiUpdateGuardian() internal view returns (Role memory) {
        bytes4 selector = IWithGuardian.updateGuardian.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: CRITICAL_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
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
    function getRole__setWithdrawalQueue() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.setWithdrawalQueue.selector;
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
    /// @custom:location Allocator, FundsHandler, EarningChainGateway, StableVault, AccountingChainGateway, CcipAdapter,
    /// AdiAdapter
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
    /// @custom:location CcipAdapter, AdiAdapter, StableVault, AccountingChainGateway, FundsHandler, EarningChainGateway
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
            hasCriticalRisk: false
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
            hasCriticalRisk: false
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
            hasCriticalRisk: false
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
            hasCriticalRisk: false
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
            hasCriticalRisk: false
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
            hasCriticalRisk: false
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
        bytes4 selector = SlippageCoverageVault.enableOverrideMode.selector;
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
        bytes4 selector = SlippageCoverageVault.disableOverrideMode.selector;
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
        bytes4 selector = SlippageCoverageVault.raisePullCapPerTx.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__lowerPullCapPerTx() internal pure returns (Role memory) {
        bytes4 selector = SlippageCoverageVault.lowerPullCapPerTx.selector;
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
        bytes4 selector = SlippageCoverageVault.raiseWindowCap.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__lowerWindowCap() internal pure returns (Role memory) {
        bytes4 selector = SlippageCoverageVault.lowerWindowCap.selector;
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
        bytes4 selector = SlippageCoverageVault.raiseWindowSeconds.selector;
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
        bytes4 selector = SlippageCoverageVault.lowerWindowSeconds.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location SlippageCoverageVault
    function getRole__setMaxSlippageBps() internal view returns (Role memory) {
        bytes4 selector = SlippageCoverageVault.setMaxSlippageBps.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay High
    /// @custom:location SlippageCoverageVault
    function getRole__setOverrideMaxSlippageBps() internal view returns (Role memory) {
        bytes4 selector = SlippageCoverageVault.setOverrideMaxSlippageBps.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location SlippageCoverageVault
    function getRole__fundCoverage() internal pure returns (Role memory) {
        bytes4 selector = SlippageCoverageVault.fundCoverage.selector;
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
        bytes4 selector = SlippageCoverageVault.sweep.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: HIGH_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    function getAllFunctionBasedRoles() internal view returns (Role[] memory) {
        Role[] memory roles = new Role[](87);

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
        roles[11] = getRole__addFundsBridgeAdapter();
        roles[12] = getRole__removeFundsBridgeAdapter();
        roles[13] = getRole__addDataOnlyBridgeAdapter();
        roles[14] = getRole__initiateDataOnlyBridgeAdapterRemoval();
        roles[15] = getRole__finalizeDataOnlyBridgeAdapterRemoval();

        // WithdrawalExecutionPolicy
        roles[16] = getRole__setAssetFeeBps();
        roles[17] = getRole__setDefaultFeeBps();
        roles[18] = getRole__addSigner();
        roles[19] = getRole__removeSigner();

        // BridgeAdapter
        roles[20] = getRole__setDestinationChainAdapter();
        roles[21] = getRole__setChainSelector();
        roles[22] = getRole__replayFundsReceiving();

        // StableVault
        roles[23] = getRole__setUserRate();
        roles[24] = getRole__setSubVaultRate();
        roles[25] = getRole__setDefaultSubVault();
        roles[26] = getRole__claimSurplusInterest();
        roles[27] = getRole__setTreasury();

        // Allocator
        roles[28] = getRole__rebalance();
        roles[29] = getRole__addStrategy();
        roles[30] = getRole__removeStrategy();
        roles[31] = getRole__disableDepositsToStrategy();
        roles[32] = getRole__enableDepositsToStrategy();
        roles[33] = getRole__topUp();
        roles[34] = getRole__trustStrategy();
        roles[35] = getRole__distrustStrategy();
        roles[36] = getRole__setWithdrawalQueue();

        // Rescue
        roles[37] = getRole__rescueTokens();
        roles[38] = getRole__rescueNative();

        // FundsHandler / EarningChainGateway
        roles[39] = getRole__pushFundsToChain();
        roles[40] = getRole__pushFundsToAccountingChain();
        roles[41] = getRole__addEarningChain();
        roles[42] = getRole__removeEarningChain();

        // Oracles
        roles[43] = getRole__setChainBalanceOracleAdapter();
        roles[44] = getRole__setOracleAdapterForAsset();

        // External - aToken Vault
        roles[45] = getRole__claimMerklRewards();
        roles[46] = getRole__emergencyRescue();

        // SlippageCoverageVault
        roles[47] = getRole__enableOverrideMode();
        roles[48] = getRole__disableOverrideMode();
        roles[49] = getRole__raisePullCapPerTx();
        roles[50] = getRole__lowerPullCapPerTx();
        roles[51] = getRole__raiseWindowCap();
        roles[52] = getRole__lowerWindowCap();
        roles[53] = getRole__raiseWindowSeconds();
        roles[54] = getRole__lowerWindowSeconds();
        roles[55] = getRole__setMaxSlippageBps();
        roles[56] = getRole__setOverrideMaxSlippageBps();
        roles[57] = getRole__fundCoverage();
        roles[58] = getRole__sweepSlippageCoverageVault();

        // PolicyRegistry
        roles[59] = getRole__setPolicy();

        // DepositPolicy / FundsBridgingPolicy
        roles[60] = getRole__raiseDepositCapacity();
        roles[61] = getRole__raiseDepositRefillRate();
        roles[62] = getRole__lowerDepositCapacity();
        roles[63] = getRole__lowerDepositRefillRate();
        roles[64] = getRole__raiseBridgingCapacity();
        roles[65] = getRole__raiseBridgingRefillRate();
        roles[66] = getRole__lowerBridgingCapacity();
        roles[67] = getRole__lowerBridgingRefillRate();

        // WithdrawalExecutionPolicy redemption rate-limit
        roles[68] = getRole__raiseRedemptionCapacity();
        roles[69] = getRole__raiseRedemptionRefillRate();
        roles[70] = getRole__lowerRedemptionCapacity();
        roles[71] = getRole__lowerRedemptionRefillRate();

        // a.DI CrossChainController
        roles[72] = getRole__adiApproveSenders();
        roles[73] = getRole__adiRemoveSenders();
        roles[74] = getRole__adiEnableBridgeAdapters();
        roles[75] = getRole__adiDisableBridgeAdapters();
        roles[76] = getRole__adiUpdateOptimalBandwidthByChain();
        roles[77] = getRole__adiConfigAdapter();
        roles[78] = getRole__adiUpdateRequiredForwardingSuccessesByChain();
        roles[79] = getRole__adiUpdateConfirmations();
        roles[80] = getRole__adiUpdateMessagesValidityTimestamp();
        roles[81] = getRole__adiAllowReceiverBridgeAdapters();
        roles[82] = getRole__adiDisallowReceiverBridgeAdapters();
        roles[83] = getRole__adiEmergencyTokenTransfer();
        roles[84] = getRole__adiEmergencyEtherTransfer();
        roles[85] = getRole__adiTransferOwnership();
        roles[86] = getRole__adiUpdateGuardian();

        return roles;
    }

    function _selectorToRoleId(bytes4 selector) internal pure returns (uint64) {
        return uint64(bytes8(abi.encodePacked(selector, bytes4(0))));
    }
}
