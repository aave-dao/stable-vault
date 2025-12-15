// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ATokenVaultDeployment} from "script/base/ATokenVaultDeployment.sol";
import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {Create3Deployment} from "script/base/Create3Deployment.sol";

import {ExtendedAccessManager} from "src/access/ExtendedAccessManager.sol";
import {CcipAdapter} from "src/bridging/CcipAdapter.sol";
import {Allocator} from "src/core/Allocator.sol";
import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

contract EarningChainDeployment is Create3Deployment, Create3AddressBook, ATokenVaultDeployment, Script {
    using Strings for address;

    // Base Chain ID
    uint256 constant ACCOUNTING_CHAIN_ID = 8453;
    // Base CCIP Selector
    uint64 constant ACCOUNTING_CHAIN_CCIP_SELECTOR = 15971525489660198786;

    address constant DEPLOYER = address(0xBB700dA5CCC9Ec5605780Fc40695f1206B090303);

    address constant PROXY_ADMIN = DEPLOYER;
    address constant ALLOCATOR_PROXY_ADMIN = PROXY_ADMIN;
    address constant WITHDRAWAL_POLICY_PROXY_ADMIN = PROXY_ADMIN;
    address constant ASSET_REGISTRY_PROXY_ADMIN = PROXY_ADMIN;
    address constant GATEWAY_PROXY_ADMIN = PROXY_ADMIN;
    address constant IOU_TOKEN_MANAGER_PROXY_ADMIN = PROXY_ADMIN;

    address constant ACCESS_MANAGER_ADMIN = DEPLOYER;

    address immutable ALLOCATOR_DEPOSITOR = getGatewayAddress(DEPLOYER);
    address immutable ALLOCATOR_WITHDRAWER = getGatewayAddress(DEPLOYER);

    // Set to Ethereum CCIP Router address
    address constant CCIP_ROUTER_ADDRESS = address(0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D);

    // ERC20s on Ethereum
    address GHO = address(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    address USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address USDT = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    function run() public {
        vm.startBroadcast(DEPLOYER);
        _deployContracts();
        _setupContracts();
        vm.stopBroadcast();
    }

    function _deployContracts() internal {
        _deployTransferHelper();
        _deployAccessManager();
        _deployAssetRegistry();
        _deployWithdrawalPolicy();
        _deployIouToken();
        _deployIouTokenManager();
        _deployAllocator();
        _deployGateway();
        _deploySwapper();
        _deployCcipAdapter();
    }

    function _setupContracts() internal {
        _setupAccessManager();
        _setupBridgeAdapters();
        _setupAllocator();
        _setupAssetRegistry();
    }

    function _setupAccessManager() internal {
        // Right now we just keep the admin, we should setup more roles here.
    }

    function _setupBridgeAdapters() internal {
        // NOTE: This assumes adapters of same type are having the same address on all chains.
        address localCcipAdapter = getCcipAdapterAddress(DEPLOYER);
        address accountingCcipAdapter = localCcipAdapter;

        IEarningChainGateway gateway = IEarningChainGateway(getGatewayAddress(DEPLOYER));

        // GHO uses CCIP Adapter
        gateway.addBridgeAdapter(GHO, ACCOUNTING_CHAIN_ID, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(GHO, ACCOUNTING_CHAIN_ID, localCcipAdapter);

        // USDC uses CCIP Adapter
        gateway.addBridgeAdapter(USDC, ACCOUNTING_CHAIN_ID, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(USDC, ACCOUNTING_CHAIN_ID, localCcipAdapter);

        // TODO: Add USDT bridge adapter

        // Message uses CCIP Adapter
        address messageOnly = address(0);
        gateway.addBridgeAdapter(messageOnly, ACCOUNTING_CHAIN_ID, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(messageOnly, ACCOUNTING_CHAIN_ID, localCcipAdapter);

        ICcipBridgeAdapter(localCcipAdapter).setChainSelector(ACCOUNTING_CHAIN_ID, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        ICcipBridgeAdapter(localCcipAdapter).setDestinationChainAdapter(ACCOUNTING_CHAIN_ID, accountingCcipAdapter);
    }

    function _setupAllocator() internal {
        IAllocator allocator = IAllocator(getAllocatorAddress(DEPLOYER));

        address poolAddressProvider = address(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);

        // TODO: Deploy GHO Yield Strategy, in mainnet it cannot be supplied so we cannot do aTokenVault for it.
        // address ghoYieldStrategy = address(0);
        // allocator.addStrategy(GHO, ghoYieldStrategy);
        // allocator.setDefaultStrategy(GHO, ghoYieldStrategy);

        address usdcYieldStrategy = _deployATokenVault(USDC, poolAddressProvider, DEPLOYER);
        allocator.addStrategy(USDC, usdcYieldStrategy);
        allocator.setDefaultStrategy(USDC, usdcYieldStrategy);
        _logDeployment("USDC aTokenVault", "", usdcYieldStrategy);

        address usdtYieldStrategy = _deployATokenVault(USDT, poolAddressProvider, DEPLOYER);
        allocator.addStrategy(USDT, usdtYieldStrategy);
        allocator.setDefaultStrategy(USDT, usdtYieldStrategy);
        _logDeployment("USDT aTokenVault", "", usdtYieldStrategy);
    }

    function _setupAssetRegistry() internal {
        IAssetRegistry assetRegistry = IAssetRegistry(getAssetRegistryAddress(DEPLOYER));
        IAssetRegistry.AssetConfig memory unrestrictedAssetConfig = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        assetRegistry.setAssetConfig(GHO, unrestrictedAssetConfig);
        assetRegistry.setAssetConfig(USDC, unrestrictedAssetConfig);
        assetRegistry.setAssetConfig(USDT, unrestrictedAssetConfig);
    }

    function _deployTransferHelper() internal returns (address) {
        address transferHelper = _deploy_create3({
            namespacedSaltSeed: TRANSFER_HELPER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(TransferHelper).creationCode)
        });
        require(transferHelper == getTransferHelperAddress(DEPLOYER), "TransferHelper does not match expected address");
        _logDeployment("TransferHelper", TRANSFER_HELPER_SALT_SEED, transferHelper);
        return transferHelper;
    }

    function _deployAccessManager() internal returns (address) {
        address accessManager = _deploy_create3({
            namespacedSaltSeed: ACCESS_MANAGER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(ExtendedAccessManager).creationCode, abi.encode(ACCESS_MANAGER_ADMIN))
        });
        require(accessManager == getAccessManagerAddress(DEPLOYER), "AccessManager does not match expected address");
        _logDeployment("AccessManager", ACCESS_MANAGER_SALT_SEED, accessManager);
        return accessManager;
    }

    function _deployAssetRegistry() internal returns (address) {
        address implementation = address(new AssetRegistry());
        _logDeployment("AssetRegistry::Implementation", "", implementation);
        address assetRegistry = _deployTransparentProxy_create3({
            namespacedSaltSeed: ASSET_REGISTRY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: ASSET_REGISTRY_PROXY_ADMIN,
            initCalldata: abi.encodeCall(AssetRegistry.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(assetRegistry == getAssetRegistryAddress(DEPLOYER), "AssetRegistry does not match expected address");
        _logDeployment("AssetRegistry", ASSET_REGISTRY_SALT_SEED, assetRegistry);
        return assetRegistry;
    }

    function _deployWithdrawalPolicy() internal returns (address) {
        address implementation = address(new WithdrawalPolicy({assetRegistry: getAssetRegistryAddress(DEPLOYER)}));
        _logDeployment("WithdrawalPolicy::Implementation", "", implementation);
        address withdrawalPolicy = _deployTransparentProxy_create3({
            namespacedSaltSeed: WITHDRAWAL_POLICY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: WITHDRAWAL_POLICY_PROXY_ADMIN,
            initCalldata: abi.encodeCall(WithdrawalPolicy.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(
            withdrawalPolicy == getWithdrawalPolicyAddress(DEPLOYER), "WithdrawalPolicy does not match expected address"
        );
        _logDeployment("WithdrawalPolicy", WITHDRAWAL_POLICY_SALT_SEED, withdrawalPolicy);
        return withdrawalPolicy;
    }

    function _deployIouToken() internal returns (address) {
        address iouToken = _deploy_create3({
            namespacedSaltSeed: IOU_TOKEN_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(IouToken).creationCode, abi.encode(getIouTokenManagerAddress(DEPLOYER)))
        });
        require(iouToken == getIouTokenAddress(DEPLOYER), "IouToken does not match expected address");
        _logDeployment("IouToken", IOU_TOKEN_SALT_SEED, iouToken);
        return iouToken;
    }

    function _deployIouTokenManager() internal returns (address) {
        address implementation = address(
            new IouTokenManager({
                iouToken: getIouTokenAddress(DEPLOYER),
                chainGateway: getGatewayAddress(DEPLOYER),
                vault: getBasedBoostedVaultAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER),
                isAccountingChain: false
            })
        );
        _logDeployment("IouTokenManager::Implementation", "", implementation);
        address iouTokenManager = _deployTransparentProxy_create3({
            namespacedSaltSeed: IOU_TOKEN_MANAGER_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: IOU_TOKEN_MANAGER_PROXY_ADMIN,
            initCalldata: ""
        });
        require(
            iouTokenManager == getIouTokenManagerAddress(DEPLOYER), "IouTokenManager does not match expected address"
        );
        _logDeployment("IouTokenManager", IOU_TOKEN_MANAGER_SALT_SEED, iouTokenManager);
        return iouTokenManager;
    }

    function _deployAllocator() internal returns (address) {
        address implementation = address(
            new Allocator({
                assetRegistry: getAssetRegistryAddress(DEPLOYER),
                depositor: ALLOCATOR_DEPOSITOR,
                withdrawer: ALLOCATOR_WITHDRAWER,
                transferHelper: getTransferHelperAddress(DEPLOYER)
            })
        );
        _logDeployment("Allocator::Implementation", "", implementation);
        address allocator = _deployTransparentProxy_create3({
            namespacedSaltSeed: ALLOCATOR_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: ALLOCATOR_PROXY_ADMIN,
            initCalldata: abi.encodeCall(Allocator.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(allocator == getAllocatorAddress(DEPLOYER), "Allocator does not match expected address");
        _logDeployment("Allocator", ALLOCATOR_SALT_SEED, allocator);
        return allocator;
    }

    function _deployGateway() internal returns (address) {
        address implementation = address(
            new EarningChainGateway({
                accountingChainId: ACCOUNTING_CHAIN_ID,
                allocator: getAllocatorAddress(DEPLOYER),
                iouTokenManager: getIouTokenManagerAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER),
                withdrawalPolicy: getWithdrawalPolicyAddress(DEPLOYER)
            })
        );
        _logDeployment("EarningChainGateway::Implementation", "", implementation);
        address gateway = _deployTransparentProxy_create3({
            namespacedSaltSeed: GATEWAY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: GATEWAY_PROXY_ADMIN,
            initCalldata: abi.encodeCall(EarningChainGateway.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(gateway == getGatewayAddress(DEPLOYER), "Gateway does not match expected address");
        _logDeployment("EarningChainGateway", GATEWAY_SALT_SEED, gateway);
        return gateway;
    }

    function _deploySwapper() internal returns (address) {
        address swapper = _deploy_create3({
            namespacedSaltSeed: SWAPPER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(Swapper).creationCode, abi.encode(getAllocatorAddress(DEPLOYER)))
        });
        require(swapper == getSwapperAddress(DEPLOYER), "Swapper does not match expected address");
        _logDeployment("Swapper", SWAPPER_SALT_SEED, swapper);
        return swapper;
    }

    function _deployCcipAdapter() internal returns (address) {
        address ccipAdapter = _deploy_create3({
            namespacedSaltSeed: CCIP_ADAPTER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(
                type(CcipAdapter).creationCode,
                abi.encode(
                    getAccessManagerAddress(DEPLOYER),
                    getGatewayAddress(DEPLOYER),
                    CCIP_ROUTER_ADDRESS,
                    getTransferHelperAddress(DEPLOYER)
                )
            )
        });
        require(ccipAdapter == getCcipAdapterAddress(DEPLOYER), "CcipAdapter does not match expected address");
        _logDeployment("CcipAdapter", CCIP_ADAPTER_SALT_SEED, ccipAdapter);
        return ccipAdapter;
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/earning.json", string.concat(".", name));
    }
}
