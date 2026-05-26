// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ATokenVaultProxyAddressLib} from "script/libraries/ATokenVaultProxyAddressLib.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

contract Create3AddressBook {
    using Strings for address;

    string constant STABLE_VAULT_SALT_SEED = "aave.stable-vault.StableVault";
    string constant TRANSFER_HELPER_SALT_SEED = "aave.stable-vault.TransferHelper";
    string constant WITHDRAWAL_EXECUTION_POLICY_SALT_SEED = "aave.stable-vault.WithdrawalExecutionPolicy";
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
    string constant ADI_ADAPTER_SALT_SEED = "aave.stable-vault.AdiAdapter";
    string constant PRICE_ORACLE_SALT_SEED = "aave.stable-vault.PriceOracle";
    string constant CHAIN_BALANCE_ORACLE_SALT_SEED = "aave.stable-vault.ChainBalanceOracle";
    string constant EARNING_CHAIN_STATE_PROVIDER_SALT_SEED = "aave.stable-vault.EarningChainStateProvider";
    string constant POLICY_REGISTRY_SALT_SEED = "aave.stable-vault.PolicyRegistry";
    string constant DEPOSIT_POLICY_SALT_SEED = "aave.stable-vault.DepositPolicy";
    string constant FUNDS_BRIDGING_POLICY_SALT_SEED = "aave.stable-vault.FundsBridgingPolicy";
    string constant ATOKEN_VAULT_PROXY_DEPLOYER_SALT_SEED_PREFIX = "aave.stable-vault.ATokenVault.ProxyDeployer.";
    string constant ATOKEN_VAULT_MERKL_REWARD_CLAIMER_IMPL_SALT_SEED_PREFIX =
        "aave.stable-vault.ATokenVaultMerklRewardClaimer.Impl.";
    string constant CHAINLINK_PRICE_ORACLE_ADAPTER_SALT_SEED_PREFIX = "aave.stable-vault.ChainlinkPriceOracleAdapter.";
    string constant CHAINLINK_L2_PRICE_ORACLE_ADAPTER_SALT_SEED_PREFIX =
        "aave.stable-vault.ChainlinkL2PriceOracleAdapter.";
    string constant CHAINLINK_L2_CHAIN_BALANCE_ORACLE_ADAPTER_SALT_SEED_PREFIX =
        "aave.stable-vault.ChainlinkL2ChainBalanceOracleAdapter.";
    string constant MOCK_BUNDLE_FEED_SALT_SEED = "aave.stable-vault.MockBundleFeed";
    string constant MOCK_SEQUENCER_UPTIME_FEED_SALT_SEED = "aave.stable-vault.MockSequencerUptimeFeed";

    function getStableVaultAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(STABLE_VAULT_SALT_SEED, deployer);
    }

    function getTransferHelperAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(TRANSFER_HELPER_SALT_SEED, deployer);
    }

    function getWithdrawalExecutionPolicyAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(WITHDRAWAL_EXECUTION_POLICY_SALT_SEED, deployer);
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

    function getAdiAdapterAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(ADI_ADAPTER_SALT_SEED, deployer);
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

    function getPolicyRegistryAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(POLICY_REGISTRY_SALT_SEED, deployer);
    }

    function getDepositPolicyAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(DEPOSIT_POLICY_SALT_SEED, deployer);
    }

    function getFundsBridgingPolicyAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(FUNDS_BRIDGING_POLICY_SALT_SEED, deployer);
    }

    function getATokenVaultAddress(address underlying, address deployer) internal pure virtual returns (address) {
        return ATokenVaultProxyAddressLib.computeProxyAddress(_getATokenVaultProxyDeployerAddress(underlying, deployer));
    }

    function getATokenVaultProxyDeployerSaltSeed(address underlying) internal pure virtual returns (string memory) {
        return string.concat(ATOKEN_VAULT_PROXY_DEPLOYER_SALT_SEED_PREFIX, underlying.toHexString());
    }

    function getATokenVaultMerklRewardClaimerImplSaltSeed(address underlying)
        internal
        pure
        virtual
        returns (string memory)
    {
        return string.concat(ATOKEN_VAULT_MERKL_REWARD_CLAIMER_IMPL_SALT_SEED_PREFIX, underlying.toHexString());
    }

    function getChainlinkPriceOracleAdapterSaltSeed(address asset) internal pure virtual returns (string memory) {
        return string.concat(CHAINLINK_PRICE_ORACLE_ADAPTER_SALT_SEED_PREFIX, asset.toHexString());
    }

    function getChainlinkPriceOracleAdapterAddress(address asset, address deployer)
        internal
        pure
        virtual
        returns (address)
    {
        return Create3AddressLib.computeCreate3Address(getChainlinkPriceOracleAdapterSaltSeed(asset), deployer);
    }

    function getChainlinkL2PriceOracleAdapterSaltSeed(address asset) internal pure virtual returns (string memory) {
        return string.concat(CHAINLINK_L2_PRICE_ORACLE_ADAPTER_SALT_SEED_PREFIX, asset.toHexString());
    }

    function getChainlinkL2PriceOracleAdapterAddress(address asset, address deployer)
        internal
        pure
        virtual
        returns (address)
    {
        return Create3AddressLib.computeCreate3Address(getChainlinkL2PriceOracleAdapterSaltSeed(asset), deployer);
    }

    function getChainlinkL2ChainBalanceOracleAdapterSaltSeed(uint256 chainId)
        internal
        pure
        virtual
        returns (string memory)
    {
        return string.concat(CHAINLINK_L2_CHAIN_BALANCE_ORACLE_ADAPTER_SALT_SEED_PREFIX, Strings.toString(chainId));
    }

    function getChainlinkL2ChainBalanceOracleAdapterAddress(uint256 chainId, address deployer)
        internal
        pure
        virtual
        returns (address)
    {
        return Create3AddressLib.computeCreate3Address(
            getChainlinkL2ChainBalanceOracleAdapterSaltSeed(chainId), deployer
        );
    }

    function getMockBundleFeedAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(MOCK_BUNDLE_FEED_SALT_SEED, deployer);
    }

    function getMockSequencerUptimeFeedAddress(address deployer) internal pure virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(MOCK_SEQUENCER_UPTIME_FEED_SALT_SEED, deployer);
    }

    function _getATokenVaultProxyDeployerAddress(address underlying, address deployer) private pure returns (address) {
        return Create3AddressLib.computeCreate3Address(getATokenVaultProxyDeployerSaltSeed(underlying), deployer);
    }
}
