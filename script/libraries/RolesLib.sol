// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBasedBoostedVault} from "src/interfaces/IBasedBoostedVault.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

library RolesLib {
    uint32 constant CRITICAL_DELAY = 21 days;
    uint32 constant MED_DELAY = 7 days;
    uint32 constant NO_DELAY = 0;

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

    /// @custom:delay Medium
    /// @custom:location AssetRegistry
    function getRole__setAssetConfig() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.setAssetConfig.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
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

    /// @custom:delay Medium
    /// @custom:location AssetRegistry
    function getRole__enableAllocatorDeposits() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.enableAllocatorDeposits.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location AssetRegistry
    function getRole__enableSwapInput() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.enableSwapInput.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location AssetRegistry
    function getRole__enableSwapOutput() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.enableSwapOutput.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location AssetRegistry
    function getRole__enableUserDeposits() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.enableUserDeposits.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location AssetRegistry
    function getRole__trustAsset() internal pure returns (Role memory) {
        bytes4 selector = IAssetRegistry.trustAsset.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
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

    /// @custom:delay Medium
    /// @custom:location EarningChainGateway, AccountingChainGateway
    function getRole__addBridgeAdapter() internal pure returns (Role memory) {
        bytes4 selector = IChainGateway.addBridgeAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
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
    /// @custom:location EarningChainGateway, AccountingChainGateway
    function getRole__setDefaultBridgeAdapter() internal pure returns (Role memory) {
        bytes4 selector = IChainGateway.setDefaultBridgeAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location WithdrawalPolicy
    function getRole__setAssetFeeBps() internal pure returns (Role memory) {
        bytes4 selector = WithdrawalPolicy.setAssetFeeBps.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location WithdrawalPolicy
    function getRole__setDefaultFeeBps() internal pure returns (Role memory) {
        bytes4 selector = WithdrawalPolicy.setDefaultFeeBps.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location WithdrawalPolicy
    function getRole__setSigner() internal pure returns (Role memory) {
        bytes4 selector = WithdrawalPolicy.setSigner.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location CcipAdapter
    function getRole__setDestinationChainAdapter() internal pure returns (Role memory) {
        bytes4 selector = IBridgeAdapter.setDestinationChainAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay None
    /// @custom:location BasedBoostedVault
    function getRole__setUserRate() internal pure returns (Role memory) {
        bytes4 selector = IBasedBoostedVault.setUserRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location BasedBoostedVault
    function getRole__setSubVaultRate() internal pure returns (Role memory) {
        bytes4 selector = IBasedBoostedVault.setSubVaultRate.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location BasedBoostedVault
    function getRole__setDefaultSubVault() internal pure returns (Role memory) {
        bytes4 selector = IBasedBoostedVault.setDefaultSubVault.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location BasedBoostedVault
    function getRole__claimSurplusInterest() internal pure returns (Role memory) {
        bytes4 selector = IBasedBoostedVault.claimSurplusInterest.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location BasedBoostedVault
    function getRole__setTreasury() internal pure returns (Role memory) {
        bytes4 selector = IBasedBoostedVault.setTreasury.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Medium
    /// @custom:location CcipAdapter
    function getRole__setChainSelector() internal pure returns (Role memory) {
        bytes4 selector = ICcipBridgeAdapter.setChainSelector.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
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

    /// @custom:delay Medium
    /// @custom:location Allocator
    function getRole__addStrategy() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.addStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
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

    /// @custom:delay Medium
    /// @custom:location Allocator
    function getRole__enableDepositsToStrategy() internal pure returns (Role memory) {
        bytes4 selector = IAllocator.enableDepositsToStrategy.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location FundsHandler, EarningChainGateway, BasedBoostedVault, AccountingChainGateway
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
    /// @custom:location CcipAdapter, BasedBoostedVault, AccountingChainGateway, FundsHandler, EarningChainGateway
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

    /// @custom:delay Medium
    /// @custom:location FundsHandler
    function getRole__addEarningChain() internal pure returns (Role memory) {
        bytes4 selector = IFundsHandler.addEarningChain.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay Medium
    /// @custom:location FundsHandler
    function getRole__removeEarningChain() internal pure returns (Role memory) {
        bytes4 selector = IFundsHandler.removeEarningChain.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
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

    /// @custom:delay Medium
    /// @custom:location ChainBalanceOracle
    function getRole__setChainBalanceOracleAdapter() internal pure returns (Role memory) {
        bytes4 selector = ChainBalanceOracle.setChainBalanceOracleAdapter.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: true
        });
    }

    /// @custom:delay Medium
    /// @custom:location PriceOracle
    function getRole__setOracleAdapterForAsset() internal pure returns (Role memory) {
        bytes4 selector = PriceOracle.setOracleAdapterForAsset.selector;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: MED_DELAY,
            guardianRoleId: ADMIN_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    /// @custom:delay None
    /// @custom:location aToken Vault
    function getRole__claimMerklRewards() internal pure returns (Role memory) {
        bytes4 selector = 0x685463c1;
        return Role({
            roleId: _selectorToRoleId(selector),
            selector: selector,
            delay: NO_DELAY,
            guardianRoleId: OPERATIONAL_ROLE_GUARDIAN_ROLE,
            hasCriticalRisk: false
        });
    }

    function getAllFunctionBasedRoles() internal pure returns (Role[] memory) {
        Role[] memory roles = new Role[](40);

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
        roles[13] = getRole__setDefaultBridgeAdapter();

        // WithdrawalPolicy
        roles[14] = getRole__setAssetFeeBps();
        roles[15] = getRole__setDefaultFeeBps();
        roles[16] = getRole__setSigner();

        // BridgeAdapter
        roles[17] = getRole__setDestinationChainAdapter();
        roles[18] = getRole__setChainSelector();
        roles[19] = getRole__replayFundsReceiving();

        // BasedBoostedVault
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

        // Rescue
        roles[31] = getRole__rescueTokens();
        roles[32] = getRole__rescueNative();

        // FundsHandler / EarningChainGateway
        roles[33] = getRole__pushFundsToChain();
        roles[34] = getRole__pushFundsToAccountingChain();
        roles[35] = getRole__addEarningChain();
        roles[36] = getRole__removeEarningChain();

        // Oracles
        roles[37] = getRole__setChainBalanceOracleAdapter();
        roles[38] = getRole__setOracleAdapterForAsset();

        // External - aToken Vault
        roles[39] = getRole__claimMerklRewards();

        return roles;
    }

    function _selectorToRoleId(bytes4 selector) internal pure returns (uint64) {
        return uint64(bytes8(abi.encodePacked(selector, bytes4(0))));
    }
}
