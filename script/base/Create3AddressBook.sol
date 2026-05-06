// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

contract Create3AddressBook {
    string constant STABLE_VAULT_SALT_SEED = "aave.stable-vault.StableVault";
    string constant TRANSFER_HELPER_SALT_SEED = "aave.stable-vault.TransferHelper";
    string constant WITHDRAWAL_POLICY_SALT_SEED = "aave.stable-vault.WithdrawalPolicy";
    string constant FUNDS_HANDLER_SALT_SEED = "aave.stable-vault.FundsHandler";
    string constant ALLOCATOR_SALT_SEED = "aave.stable-vault.Allocator";
    string constant GATEWAY_SALT_SEED = "aave.stable-vault.Gateway";
    string constant ACCESS_MANAGER_SALT_SEED = "aave.stable-vault.AccessManager";
    string constant ASSET_REGISTRY_SALT_SEED = "aave.stable-vault.AssetRegistry";
    string constant IOU_TOKEN_MANAGER_SALT_SEED = "aave.stable-vault.IouTokenManager";
    string constant IOU_TOKEN_SALT_SEED = "aave.stable-vault.IouToken";
    string constant SLIPPAGE_COVERAGE_VAULT_SALT_SEED = "aave.stable-vault.SlippageCoverageVault";
    string constant SWAPPER_SALT_SEED = "aave.stable-vault.Swapper";
    string constant CCIP_ADAPTER_SALT_SEED = "aave.stable-vault.CcipAdapter";
    string constant PRICE_ORACLE_SALT_SEED = "aave.stable-vault.PriceOracle";
    string constant CHAIN_BALANCE_ORACLE_SALT_SEED = "aave.stable-vault.ChainBalanceOracle";
    string constant EARNING_CHAIN_STATE_PROVIDER_SALT_SEED = "aave.stable-vault.EarningChainStateProvider";

    function getStableVaultAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(STABLE_VAULT_SALT_SEED, deployer);
    }

    function getTransferHelperAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(TRANSFER_HELPER_SALT_SEED, deployer);
    }

    function getWithdrawalPolicyAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(WITHDRAWAL_POLICY_SALT_SEED, deployer);
    }

    function getFundsHandlerAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(FUNDS_HANDLER_SALT_SEED, deployer);
    }

    function getAllocatorAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(ALLOCATOR_SALT_SEED, deployer);
    }

    function getGatewayAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(GATEWAY_SALT_SEED, deployer);
    }

    function getAccessManagerAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(ACCESS_MANAGER_SALT_SEED, deployer);
    }

    function getAssetRegistryAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(ASSET_REGISTRY_SALT_SEED, deployer);
    }

    function getIouTokenManagerAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(IOU_TOKEN_MANAGER_SALT_SEED, deployer);
    }

    function getIouTokenAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(IOU_TOKEN_SALT_SEED, deployer);
    }

    function getSlippageCoverageVaultAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(SLIPPAGE_COVERAGE_VAULT_SALT_SEED, deployer);
    }

    function getSwapperAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(SWAPPER_SALT_SEED, deployer);
    }

    function getCcipAdapterAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(CCIP_ADAPTER_SALT_SEED, deployer);
    }

    function getPriceOracleAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(PRICE_ORACLE_SALT_SEED, deployer);
    }

    function getChainBalanceOracleAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(CHAIN_BALANCE_ORACLE_SALT_SEED, deployer);
    }

    function getEarningChainStateProviderAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(EARNING_CHAIN_STATE_PROVIDER_SALT_SEED, deployer);
    }
}
