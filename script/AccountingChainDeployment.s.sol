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
import {AccountingChainGateway} from "src/core/accounting/AccountingChainGateway.sol";
import {BasedBoostedVault} from "src/core/accounting/BasedBoostedVault.sol";
import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

contract AccountingChainDeployment is Create3Deployment, Create3AddressBook, ATokenVaultDeployment, Script {
    using Strings for address;

    address constant DEPLOYER = address(0xBB700dA5CCC9Ec5605780Fc40695f1206B090303);

    uint256 constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    uint256 constant DEFAULT_SUB_VAULT_PER_SECOND_RATE = 1000000001243680656318820313; // ~4% APY
    uint256 constant DEFAULT_MAX_ACTIVE_SUB_VAULTS = 201;

    address constant PROXY_ADMIN = DEPLOYER;
    address constant BBV_PROXY_ADMIN = PROXY_ADMIN;
    address constant ALLOCATOR_PROXY_ADMIN = PROXY_ADMIN;
    address constant WITHDRAWAL_POLICY_PROXY_ADMIN = PROXY_ADMIN;
    address constant ASSET_REGISTRY_PROXY_ADMIN = PROXY_ADMIN;
    address constant GATEWAY_PROXY_ADMIN = PROXY_ADMIN;
    address constant IOU_TOKEN_MANAGER_PROXY_ADMIN = PROXY_ADMIN;
    address constant FUNDS_HANDLER_PROXY_ADMIN = PROXY_ADMIN;

    address constant ACCESS_MANAGER_ADMIN = DEPLOYER;

    address immutable ALLOCATOR_DEPOSITOR = getFundsHandlerAddress(DEPLOYER);
    address immutable ALLOCATOR_WITHDRAWER = getFundsHandlerAddress(DEPLOYER);

    // Set to Base CCIP Router address
    address constant CCIP_ROUTER_ADDRESS = address(0x881e3A65B4d4a04dD529061dd0071cf975F58bCD);

    // ERC20s on Base
    address GHO = address(0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee);
    address USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

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
        _deployBasedBoostedVault();
        _deployAllocator();
        _deployFundsHandler();
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
        address mainnetCcipAdapter = localCcipAdapter;

        IAccountingChainGateway gateway = IAccountingChainGateway(getGatewayAddress(DEPLOYER));

        uint256 mainnetChainId = 1;
        uint64 mainnetCcipChainSelector = 5009297550715157269;

        // GHO uses CCIP Adapter
        gateway.addBridgeAdapter(GHO, mainnetChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(GHO, mainnetChainId, localCcipAdapter);

        // USDC uses CCIP Adapter
        gateway.addBridgeAdapter(USDC, mainnetChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(USDC, mainnetChainId, localCcipAdapter);

        // TODO: Add USDT bridge adapter

        // Message uses CCIP Adapter
        address messageOnly = address(0);
        gateway.addBridgeAdapter(messageOnly, mainnetChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(messageOnly, mainnetChainId, localCcipAdapter);

        ICcipBridgeAdapter(localCcipAdapter).setChainSelector(mainnetChainId, mainnetCcipChainSelector);
        ICcipBridgeAdapter(localCcipAdapter).setDestinationChainAdapter(mainnetChainId, mainnetCcipAdapter);
    }

    function _setupAllocator() internal {
        IAllocator allocator = IAllocator(getAllocatorAddress(DEPLOYER));

        address poolAddressProvider = address(0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D);

        address ghoYieldStrategy = _deployATokenVault(GHO, poolAddressProvider, DEPLOYER);
        allocator.addStrategy(GHO, ghoYieldStrategy);
        allocator.setDefaultStrategy(GHO, ghoYieldStrategy);
        _logDeployment("GHO aTokenVault", "", ghoYieldStrategy);

        address usdcYieldStrategy = _deployATokenVault(USDC, poolAddressProvider, DEPLOYER);
        allocator.addStrategy(USDC, usdcYieldStrategy);
        allocator.setDefaultStrategy(USDC, usdcYieldStrategy);
        _logDeployment("USDC aTokenVault", "", usdcYieldStrategy);

        // TODO: Add USDT yield strategy
    }

    function _setupAssetRegistry() internal {
        IAssetRegistry assetRegistry = IAssetRegistry(getAssetRegistryAddress(DEPLOYER));
        IAssetRegistry.AssetConfig memory unrestrictedAssetConfig = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            withdrawToUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            withdrawFromAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        assetRegistry.setAssetConfig(GHO, unrestrictedAssetConfig);
        assetRegistry.setAssetConfig(USDC, unrestrictedAssetConfig);
        // TODO: Add USDT asset config
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
                isAccountingChain: true
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

    function _deployBasedBoostedVault() internal returns (address) {
        address implementation = address(
            new BasedBoostedVault({
                maxValidPerSecondRate: DEFAULT_MAX_PER_SECOND_RATE,
                assetRegistry: getAssetRegistryAddress(DEPLOYER),
                iouTokenManager: getIouTokenManagerAddress(DEPLOYER),
                fundsHandler: getFundsHandlerAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER),
                withdrawalPolicy: getWithdrawalPolicyAddress(DEPLOYER),
                maxActiveSubVaults: DEFAULT_MAX_ACTIVE_SUB_VAULTS
            })
        );
        _logDeployment("BasedBoostedVault::Implementation", "", implementation);
        address bbv = _deployTransparentProxy_create3({
            namespacedSaltSeed: BASED_BOOSTED_VAULT_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: BBV_PROXY_ADMIN,
            initCalldata: abi.encodeCall(
                BasedBoostedVault.initialize, (getAccessManagerAddress(DEPLOYER), DEFAULT_SUB_VAULT_PER_SECOND_RATE)
            )
        });
        require(bbv == getBasedBoostedVaultAddress(DEPLOYER), "BasedBoostedVault does not match expected address");
        _logDeployment("BasedBoostedVault", BASED_BOOSTED_VAULT_SALT_SEED, bbv);
        return bbv;
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

    function _deployFundsHandler() internal returns (address) {
        address implementation = address(
            new FundsHandler({
                basedBoostedVault: getBasedBoostedVaultAddress(DEPLOYER),
                gateway: getGatewayAddress(DEPLOYER),
                allocator: getAllocatorAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER)
            })
        );
        _logDeployment("FundsHandler::Implementation", "", implementation);
        address fundsHandler = _deployTransparentProxy_create3({
            namespacedSaltSeed: FUNDS_HANDLER_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: FUNDS_HANDLER_PROXY_ADMIN,
            initCalldata: abi.encodeCall(FundsHandler.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(fundsHandler == getFundsHandlerAddress(DEPLOYER), "FundsHandler does not match expected address");
        _logDeployment("FundsHandler", FUNDS_HANDLER_SALT_SEED, fundsHandler);
        return fundsHandler;
    }

    function _deployGateway() internal returns (address) {
        address implementation = address(
            new AccountingChainGateway({
                fundsHandler: getFundsHandlerAddress(DEPLOYER), iouTokenManager: getIouTokenManagerAddress(DEPLOYER)
            })
        );
        _logDeployment("AccountingChainGateway::Implementation", "", implementation);
        address gateway = _deployTransparentProxy_create3({
            namespacedSaltSeed: GATEWAY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: GATEWAY_PROXY_ADMIN,
            initCalldata: abi.encodeCall(AccountingChainGateway.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(gateway == getGatewayAddress(DEPLOYER), "Gateway does not match expected address");
        _logDeployment("AccountingChainGateway", GATEWAY_SALT_SEED, gateway);
        return gateway;
    }

    function _deploySwapper() internal returns (address) {
        address swapper = _deploy_create3({
            namespacedSaltSeed: SWAPPER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(Swapper).creationCode, abi.encode(getAllocatorAddress(DEPLOYER)))
        });
        require(swapper == getSwapperAddress(DEPLOYER), "Swapper does not match expected address");
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
        vm.writeJson(jsonObject, "deployments/vnet/accounting.json", string.concat(".", name));
    }
}
