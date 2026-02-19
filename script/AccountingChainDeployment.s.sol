// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AccessManager} from "openzeppelin-contracts/contracts/access/manager/AccessManager.sol";

import {ATokenVaultDeployment} from "script/base/ATokenVaultDeployment.sol";
import {AccessManagerAccountingChainSetup} from "script/base/AccessManagerAccountingChainSetup.sol";
import {Create3Deployment} from "script/base/Create3Deployment.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";

import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
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
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {
    ChainlinkChainBalanceOracleAdapter,
    IBundleBaseAggregator
} from "src/oracles/balance/ChainlinkChainBalanceOracleAdapter.sol";
import {AggregatorV3Interface, ChainlinkPriceOracleAdapter} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

contract AccountingChainDeployment is
    Create3Deployment,
    AccessManagerAccountingChainSetup,
    ATokenVaultDeployment,
    Script
{
    using Strings for address;

    address[] internal _deployedATokenVaults;

    address constant DEPLOYER = address(0xBB700dA5CCC9Ec5605780Fc40695f1206B090303);

    uint256 constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    uint256 constant DEFAULT_SUB_VAULT_PER_SECOND_RATE = 1000000001243680656318820313; // ~4% APY
    uint256 constant DEFAULT_MAX_ACTIVE_SUB_VAULTS = 201;
    uint8 constant MAX_STRATEGIES_PER_ASSET = 15;
    uint8 constant STRATEGY_MAX_SLIPPAGE_AMOUNT = 10; // 10 wei

    address immutable PROXY_ADMIN_OWNER = getAccessManagerAddress(DEPLOYER);
    address immutable BBV_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable ALLOCATOR_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable WITHDRAWAL_POLICY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable ASSET_REGISTRY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable GATEWAY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable IOU_TOKEN_MANAGER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable FUNDS_HANDLER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable PRICE_ORACLE_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable CHAIN_BALANCE_ORACLE_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;

    address constant ACCESS_MANAGER_ADMIN = DEPLOYER;
    address constant TREASURY = HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE;

    address immutable ALLOCATOR_DEPOSITOR = getFundsHandlerAddress(DEPLOYER);
    address immutable ALLOCATOR_WITHDRAWER = getFundsHandlerAddress(DEPLOYER);

    uint256 constant PRICE_ORACLE_MIN_VALID_PRICE_RAY = 0.99e27; // TODO: Revisit min valid price
    uint256 constant CHAINLINK_PRICE_ORACLE_HEARTBEAT = 24 hours; // TODO: Revisit heartbeat

    // TODO: Set Chainlink data feed addresses
    address constant CHAINLINK_GHO_USD_DATA_FEED = address(0);
    address constant CHAINLINK_USDC_USD_DATA_FEED = address(0);

    // Ethereum mainnet
    uint256 constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint64 constant ETHEREUM_MAINNET_CCIP_SELECTOR = 5009297550715157269;

    uint256 constant EARNING_CHAIN_ID = ETHEREUM_MAINNET_CHAIN_ID;
    uint256 constant CHAINLINK_CHAIN_BALANCE_ORACLE_HEARTBEAT = 24 hours; // TODO: Revisit heartbeat
    address constant CHAINLINK_CHAIN_BALANCE_BUNDLE_AGGREGATOR_PROXY = address(0); // TODO: Set Chainlink bundle
    // aggregator proxy address

    // Set to Base CCIP Router address
    address constant CCIP_ROUTER_ADDRESS = address(0x881e3A65B4d4a04dD529061dd0071cf975F58bCD);

    // ERC20s on Base
    address GHO = address(0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee);
    address USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    function run() public {
        _validateExternalAddresses();
        vm.startBroadcast(DEPLOYER);
        _deployContracts();
        _setupContracts();
        vm.stopBroadcast();
    }

    function _validateExternalAddresses() internal view {
        // Validate ERC20 token addresses
        IERC20(GHO).balanceOf(DEPLOYER);
        IERC20(USDC).balanceOf(DEPLOYER);

        // Validate Chainlink price feed addresses
        require(CHAINLINK_GHO_USD_DATA_FEED != address(0), "Chainlink GHO/USD data feed not set");
        AggregatorV3Interface(CHAINLINK_GHO_USD_DATA_FEED).latestRoundData();
        require(CHAINLINK_USDC_USD_DATA_FEED != address(0), "Chainlink USDC/USD data feed not set");
        AggregatorV3Interface(CHAINLINK_USDC_USD_DATA_FEED).latestRoundData();

        // Validate Chainlink bundle aggregator proxy
        require(
            CHAINLINK_CHAIN_BALANCE_BUNDLE_AGGREGATOR_PROXY != address(0), "Chainlink bundle aggregator proxy not set"
        );
        IBundleBaseAggregator(CHAINLINK_CHAIN_BALANCE_BUNDLE_AGGREGATOR_PROXY).latestBundle();

        // Validate CCIP router
        require(
            IRouterClient(CCIP_ROUTER_ADDRESS).isChainSupported(ETHEREUM_MAINNET_CCIP_SELECTOR),
            "CCIP Router does not support earning chain"
        );
    }

    function _deployContracts() internal {
        _deployTransferHelper();
        _deployAccessManager();
        _deployAssetRegistry();
        _deployWithdrawalPolicy();
        _deployIouToken();
        _deployIouTokenManager();
        _deployPriceOracle();
        _deployChainBalanceOracle();
        _deployBasedBoostedVault();
        _deployAllocator();
        _deployFundsHandler();
        _deployGateway();
        _deploySwapper();
        _deployCcipAdapter();
    }

    function _setupContracts() internal {
        _setupBridgeAdapters();
        _setupAssetRegistry();
        _setupAllocator();
        _setupAccessManager(DEPLOYER);
        _setupPriceOracleAdapters();
        _setupChainBalanceOracleAdapters();
    }

    function _accessManager() internal pure virtual override returns (address) {
        return getAccessManagerAddress(DEPLOYER);
    }

    function _setupBridgeAdapters() internal {
        // NOTE: This assumes adapters of same type are having the same address on all chains.
        address localCcipAdapter = getCcipAdapterAddress(DEPLOYER);
        address mainnetCcipAdapter = localCcipAdapter;

        IAccountingChainGateway gateway = IAccountingChainGateway(getGatewayAddress(DEPLOYER));

        uint256 mainnetChainId = ETHEREUM_MAINNET_CHAIN_ID;
        uint64 mainnetCcipChainSelector = ETHEREUM_MAINNET_CCIP_SELECTOR;

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
        allocator.addStrategy(GHO, ghoYieldStrategy, STRATEGY_MAX_SLIPPAGE_AMOUNT);
        allocator.setDefaultStrategy(GHO, ghoYieldStrategy);
        _deployedATokenVaults.push(ghoYieldStrategy);
        _logDeployment("GHO aTokenVault", "", ghoYieldStrategy);

        address usdcYieldStrategy = _deployATokenVault(USDC, poolAddressProvider, DEPLOYER);
        allocator.addStrategy(USDC, usdcYieldStrategy, STRATEGY_MAX_SLIPPAGE_AMOUNT);
        allocator.setDefaultStrategy(USDC, usdcYieldStrategy);
        _deployedATokenVaults.push(usdcYieldStrategy);
        _logDeployment("USDC aTokenVault", "", usdcYieldStrategy);

        // TODO: Add USDT yield strategy
    }

    function _aTokenVaultAddresses() internal view virtual override returns (address[] memory) {
        return _deployedATokenVaults;
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
            initCode: abi.encodePacked(type(AccessManager).creationCode, abi.encode(ACCESS_MANAGER_ADMIN))
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
            proxyAdminOwner: ASSET_REGISTRY_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(AssetRegistry.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(assetRegistry == getAssetRegistryAddress(DEPLOYER), "AssetRegistry does not match expected address");
        _logDeployment("AssetRegistry", ASSET_REGISTRY_SALT_SEED, assetRegistry);
        return assetRegistry;
    }

    function _deployWithdrawalPolicy() internal returns (address) {
        address implementation = address(new WithdrawalPolicy(getBasedBoostedVaultAddress(DEPLOYER)));
        _logDeployment("WithdrawalPolicy::Implementation", "", implementation);
        address withdrawalPolicy = _deployTransparentProxy_create3({
            namespacedSaltSeed: WITHDRAWAL_POLICY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdminOwner: WITHDRAWAL_POLICY_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(WithdrawalPolicy.initialize, (getAccessManagerAddress(DEPLOYER), 0))
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
            proxyAdminOwner: IOU_TOKEN_MANAGER_PROXY_ADMIN_OWNER,
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
                priceOracle: getPriceOracleAddress(DEPLOYER),
                maxActiveSubVaults: DEFAULT_MAX_ACTIVE_SUB_VAULTS
            })
        );
        _logDeployment("BasedBoostedVault::Implementation", "", implementation);
        address bbv = _deployTransparentProxy_create3({
            namespacedSaltSeed: BASED_BOOSTED_VAULT_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdminOwner: BBV_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(
                BasedBoostedVault.initialize,
                (getAccessManagerAddress(DEPLOYER), TREASURY, DEFAULT_SUB_VAULT_PER_SECOND_RATE)
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
                priceOracle: getPriceOracleAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER),
                maxStrategiesPerAsset: MAX_STRATEGIES_PER_ASSET
            })
        );
        _logDeployment("Allocator::Implementation", "", implementation);
        address allocator = _deployTransparentProxy_create3({
            namespacedSaltSeed: ALLOCATOR_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdminOwner: ALLOCATOR_PROXY_ADMIN_OWNER,
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
                priceOracle: getPriceOracleAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER),
                chainBalanceOracle: getChainBalanceOracleAddress(DEPLOYER)
            })
        );
        _logDeployment("FundsHandler::Implementation", "", implementation);
        address fundsHandler = _deployTransparentProxy_create3({
            namespacedSaltSeed: FUNDS_HANDLER_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdminOwner: FUNDS_HANDLER_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(FundsHandler.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(fundsHandler == getFundsHandlerAddress(DEPLOYER), "FundsHandler does not match expected address");
        _logDeployment("FundsHandler", FUNDS_HANDLER_SALT_SEED, fundsHandler);
        return fundsHandler;
    }

    function _deployGateway() internal returns (address) {
        address implementation = address(
            new AccountingChainGateway({
                fundsHandler: getFundsHandlerAddress(DEPLOYER),
                iouTokenManager: getIouTokenManagerAddress(DEPLOYER),
                chainBalanceOracle: getChainBalanceOracleAddress(DEPLOYER)
            })
        );
        _logDeployment("AccountingChainGateway::Implementation", "", implementation);
        address gateway = _deployTransparentProxy_create3({
            namespacedSaltSeed: GATEWAY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdminOwner: GATEWAY_PROXY_ADMIN_OWNER,
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
                    getTransferHelperAddress(DEPLOYER),
                    getAssetRegistryAddress(DEPLOYER)
                )
            )
        });
        require(ccipAdapter == getCcipAdapterAddress(DEPLOYER), "CcipAdapter does not match expected address");
        _logDeployment("CcipAdapter", CCIP_ADAPTER_SALT_SEED, ccipAdapter);
        return ccipAdapter;
    }

    function _deployPriceOracle() internal returns (address) {
        address implementation = address(new PriceOracle(PRICE_ORACLE_MIN_VALID_PRICE_RAY));
        _logDeployment("PriceOracle::Implementation", "", implementation);
        address priceOracle = _deployTransparentProxy_create3({
            namespacedSaltSeed: PRICE_ORACLE_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdminOwner: PRICE_ORACLE_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(PriceOracle.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(priceOracle == getPriceOracleAddress(DEPLOYER), "PriceOracle does not match expected address");
        _logDeployment("PriceOracle", PRICE_ORACLE_SALT_SEED, priceOracle);
        return priceOracle;
    }

    function _deployChainBalanceOracle() internal returns (address) {
        address implementation = address(new ChainBalanceOracle());
        _logDeployment("ChainBalanceOracle::Implementation", "", implementation);
        address chainBalanceOracle = _deployTransparentProxy_create3({
            namespacedSaltSeed: CHAIN_BALANCE_ORACLE_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdminOwner: CHAIN_BALANCE_ORACLE_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(ChainBalanceOracle.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(
            chainBalanceOracle == getChainBalanceOracleAddress(DEPLOYER),
            "ChainBalanceOracle does not match expected address"
        );
        _logDeployment("ChainBalanceOracle", CHAIN_BALANCE_ORACLE_SALT_SEED, chainBalanceOracle);
        return chainBalanceOracle;
    }

    function _setupPriceOracleAdapters() internal {
        PriceOracle priceOracle = PriceOracle(getPriceOracleAddress(DEPLOYER));

        address ghoAdapter = address(
            new ChainlinkPriceOracleAdapter(GHO, CHAINLINK_GHO_USD_DATA_FEED, CHAINLINK_PRICE_ORACLE_HEARTBEAT)
        );
        _logDeployment("ChainlinkPriceOracleAdapter::GHO", "", ghoAdapter);
        priceOracle.setOracleAdapterForAsset(GHO, ghoAdapter);

        address usdcAdapter = address(
            new ChainlinkPriceOracleAdapter(USDC, CHAINLINK_USDC_USD_DATA_FEED, CHAINLINK_PRICE_ORACLE_HEARTBEAT)
        );
        _logDeployment("ChainlinkPriceOracleAdapter::USDC", "", usdcAdapter);
        priceOracle.setOracleAdapterForAsset(USDC, usdcAdapter);
    }

    function _setupChainBalanceOracleAdapters() internal {
        address adapter = address(
            new ChainlinkChainBalanceOracleAdapter(
                EARNING_CHAIN_ID,
                CHAINLINK_CHAIN_BALANCE_BUNDLE_AGGREGATOR_PROXY,
                CHAINLINK_CHAIN_BALANCE_ORACLE_HEARTBEAT
            )
        );
        _logDeployment("ChainlinkChainBalanceOracleAdapter", "", adapter);
        ChainBalanceOracle(getChainBalanceOracleAddress(DEPLOYER))
            .setChainBalanceOracleAdapter(EARNING_CHAIN_ID, adapter);
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal virtual {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/accounting.json", string.concat(".", name));
    }
}
