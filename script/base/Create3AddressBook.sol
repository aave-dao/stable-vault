// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

contract Create3AddressBook {
    string constant BASED_BOOSTED_VAULT_SALT_SEED = "aave.based-boosted-vault.BasedBoostedVault";
    string constant TRANSFER_HELPER_SALT_SEED = "aave.based-boosted-vault.TransferHelper";
    string constant WITHDRAWAL_POLICY_SALT_SEED = "aave.based-boosted-vault.WithdrawalPolicy";
    string constant FUNDS_HANDLER_SALT_SEED = "aave.based-boosted-vault.FundsHandler";
    string constant ALLOCATOR_SALT_SEED = "aave.based-boosted-vault.Allocator";
    string constant GATEWAY_SALT_SEED = "aave.based-boosted-vault.Gateway";
    string constant ACCESS_MANAGER_SALT_SEED = "aave.based-boosted-vault.AccessManager";
    string constant ASSET_REGISTRY_SALT_SEED = "aave.based-boosted-vault.AssetRegistry";
    string constant IOU_TOKEN_MANAGER_SALT_SEED = "aave.based-boosted-vault.IouTokenManager";
    string constant IOU_TOKEN_SALT_SEED = "aave.based-boosted-vault.IouToken";
    string constant SWAPPER_SALT_SEED = "aave.based-boosted-vault.Swapper";
    string constant CCIP_ADAPTER_SALT_SEED = "aave.based-boosted-vault.CcipAdapter";

    function getBasedBoostedVaultAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(BASED_BOOSTED_VAULT_SALT_SEED, deployer);
    }

    function getTransferHelperAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(TRANSFER_HELPER_SALT_SEED, deployer);
    }

    function getWithdrawalPolicyAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(WITHDRAWAL_POLICY_SALT_SEED, deployer);
    }

    function getFundsHandlerAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(FUNDS_HANDLER_SALT_SEED, deployer);
    }

    function getAllocatorAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(ALLOCATOR_SALT_SEED, deployer);
    }

    function getGatewayAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(GATEWAY_SALT_SEED, deployer);
    }

    // TODO: How many of these do we need?
    function getAccessManagerAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(ACCESS_MANAGER_SALT_SEED, deployer);
    }

    function getAssetRegistryAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(ASSET_REGISTRY_SALT_SEED, deployer);
    }

    function getIouTokenManagerAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(IOU_TOKEN_MANAGER_SALT_SEED, deployer);
    }

    function getIouTokenAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(IOU_TOKEN_SALT_SEED, deployer);
    }

    function getSwapperAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(SWAPPER_SALT_SEED, deployer);
    }

    function getCcipAdapterAddress(address deployer) internal pure returns (address) {
        return Create3AddressLib.computeCreate3Address(CCIP_ADAPTER_SALT_SEED, deployer);
    }
}
