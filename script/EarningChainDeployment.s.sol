// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AccessManager} from "openzeppelin-contracts/contracts/access/manager/AccessManager.sol";

import {ATokenVaultDeployment} from "script/base/ATokenVaultDeployment.sol";
import {AccessManagerEarningChainSetup} from "script/base/AccessManagerEarningChainSetup.sol";
import {Create3Deployment} from "script/base/Create3Deployment.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";

import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {Allocator} from "src/core/Allocator.sol";
import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {AggregatorV3Interface, ChainlinkPriceOracleAdapter} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {EarningChainStateProvider} from "src/periphery/EarningChainStateProvider.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

contract EarningChainDeployment is Create3Deployment, AccessManagerEarningChainSetup, ATokenVaultDeployment, Script {
    using Strings for address;

    address[] internal _deployedATokenVaults;

    // Arbitrum Chain ID
    uint256 constant ACCOUNTING_CHAIN_ID = 42161;
    // Arbitrum CCIP Selector
    uint64 constant ACCOUNTING_CHAIN_CCIP_SELECTOR = 4949039107694359620;

    uint8 constant MAX_STRATEGIES_PER_ASSET = 15;
    uint8 constant STRATEGY_MAX_SLIPPAGE_AMOUNT = 10;

    address immutable PROXY_ADMIN_OWNER = getAccessManagerAddress(_deployer());
    address immutable ALLOCATOR_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable WITHDRAWAL_POLICY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable ASSET_REGISTRY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable GATEWAY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable IOU_TOKEN_MANAGER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable PRICE_ORACLE_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;

    address immutable ACCESS_MANAGER_ADMIN = _deployer();

    address immutable ALLOCATOR_DEPOSITOR = getGatewayAddress(_deployer());
    address immutable ALLOCATOR_WITHDRAWER = getGatewayAddress(_deployer());

    uint256 constant PRICE_ORACLE_MIN_VALID_PRICE_RAY = 0.99e27; // TODO: Revisit min valid price
    uint256 constant CHAINLINK_PRICE_ORACLE_HEARTBEAT = 24 hours; // TODO: Revisit heartbeat

    // ERC20s on Ethereum
    address GHO = address(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    address USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address USDT = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    // Standard
    address constant CHAINLINK_GHO_USD_DATA_FEED = address(0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC);
    // Standard - //TODO: Consider using SVR
    address constant CHAINLINK_USDC_USD_DATA_FEED = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
    // Standard - //TODO: Consider using SVR
    address constant CHAINLINK_USDT_USD_DATA_FEED = address(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D);

    // Set to Ethereum CCIP Router address
    address constant CCIP_ROUTER_ADDRESS = address(0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D);

    function run() public {
        _validateExternalAddresses();
        vm.startBroadcast(_deployer());
        _deployContracts();
        _setupContracts();
        vm.stopBroadcast();
    }

    function _validateExternalAddresses() internal view {
        // Validate ERC20 token addresses
        IERC20(GHO).balanceOf(_deployer());
        IERC20(USDC).balanceOf(_deployer());
        IERC20(USDT).balanceOf(_deployer());

        // Validate Chainlink price feed addresses
        require(CHAINLINK_GHO_USD_DATA_FEED != address(0), "Chainlink GHO/USD data feed not set");
        AggregatorV3Interface(CHAINLINK_GHO_USD_DATA_FEED).latestRoundData();
        require(CHAINLINK_USDC_USD_DATA_FEED != address(0), "Chainlink USDC/USD data feed not set");
        AggregatorV3Interface(CHAINLINK_USDC_USD_DATA_FEED).latestRoundData();
        require(CHAINLINK_USDT_USD_DATA_FEED != address(0), "Chainlink USDT/USD data feed not set");
        AggregatorV3Interface(CHAINLINK_USDT_USD_DATA_FEED).latestRoundData();

        // Validate CCIP router
        require(
            IRouterClient(CCIP_ROUTER_ADDRESS).isChainSupported(ACCOUNTING_CHAIN_CCIP_SELECTOR),
            "CCIP Router does not support accounting chain"
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
        _deployAllocator();
        _deployGateway();
        _deploySwapper();
        _deployCcipAdapter();
        _deployEarningChainStateProvider();
    }

    function _setupContracts() internal {
        _setupBridgeAdapters();
        _setupAssetRegistry();
        _setupAllocator();
        _setupAccessManager(_deployer());
        _setupPriceOracleAdapters();
    }

    function _accessManager() internal view virtual override returns (address) {
        return getAccessManagerAddress(_deployer());
    }

    function _setupBridgeAdapters() internal {
        // NOTE: This assumes adapters of same type are having the same address on all chains.
        address localCcipAdapter = getCcipAdapterAddress(_deployer());
        address accountingCcipAdapter = localCcipAdapter;

        IEarningChainGateway gateway = IEarningChainGateway(getGatewayAddress(_deployer()));

        // GHO uses CCIP Adapter
        gateway.addBridgeAdapter(GHO, ACCOUNTING_CHAIN_ID, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(GHO, ACCOUNTING_CHAIN_ID, localCcipAdapter);

        // USDC uses CCIP Adapter
        gateway.addBridgeAdapter(USDC, ACCOUNTING_CHAIN_ID, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(USDC, ACCOUNTING_CHAIN_ID, localCcipAdapter);

        // USDT uses CCIP Adapter
        gateway.addBridgeAdapter(USDT, ACCOUNTING_CHAIN_ID, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(USDT, ACCOUNTING_CHAIN_ID, localCcipAdapter);

        // Message uses CCIP Adapter
        address messageOnly = address(0);
        gateway.addBridgeAdapter(messageOnly, ACCOUNTING_CHAIN_ID, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(messageOnly, ACCOUNTING_CHAIN_ID, localCcipAdapter);

        ICcipBridgeAdapter(localCcipAdapter).setChainSelector(ACCOUNTING_CHAIN_ID, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        ICcipBridgeAdapter(localCcipAdapter).setDestinationChainAdapter(ACCOUNTING_CHAIN_ID, accountingCcipAdapter);
    }

    function _setupAllocator() internal {
        // TODO: No strategies on earning chain for now, setup sGHO once available as ERC-4626 vault
    }

    function _aTokenVaultAddresses() internal view virtual override returns (address[] memory) {
        return _deployedATokenVaults;
    }

    function _setupAssetRegistry() internal {
        IAssetRegistry assetRegistry = IAssetRegistry(getAssetRegistryAddress(_deployer()));
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
            deployer: _deployer(),
            initCode: abi.encodePacked(type(TransferHelper).creationCode)
        });
        require(
            transferHelper == getTransferHelperAddress(_deployer()), "TransferHelper does not match expected address"
        );
        _logDeployment("TransferHelper", TRANSFER_HELPER_SALT_SEED, transferHelper);
        return transferHelper;
    }

    function _deployAccessManager() internal returns (address) {
        address accessManager = _deploy_create3({
            namespacedSaltSeed: ACCESS_MANAGER_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(type(AccessManager).creationCode, abi.encode(ACCESS_MANAGER_ADMIN))
        });
        require(accessManager == getAccessManagerAddress(_deployer()), "AccessManager does not match expected address");
        _logDeployment("AccessManager", ACCESS_MANAGER_SALT_SEED, accessManager);
        return accessManager;
    }

    function _deployAssetRegistry() internal returns (address) {
        address implementation = address(new AssetRegistry());
        _logDeployment("AssetRegistry::Implementation", "", implementation);
        address assetRegistry = _deployTransparentProxy_create3({
            namespacedSaltSeed: ASSET_REGISTRY_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: ASSET_REGISTRY_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(AssetRegistry.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(assetRegistry == getAssetRegistryAddress(_deployer()), "AssetRegistry does not match expected address");
        _logDeployment("AssetRegistry", ASSET_REGISTRY_SALT_SEED, assetRegistry);
        return assetRegistry;
    }

    function _deployWithdrawalPolicy() internal returns (address) {
        address implementation = address(new WithdrawalPolicy(getGatewayAddress(_deployer())));
        _logDeployment("WithdrawalPolicy::Implementation", "", implementation);
        address withdrawalPolicy = _deployTransparentProxy_create3({
            namespacedSaltSeed: WITHDRAWAL_POLICY_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: WITHDRAWAL_POLICY_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(WithdrawalPolicy.initialize, (getAccessManagerAddress(_deployer()), 0))
        });
        require(
            withdrawalPolicy == getWithdrawalPolicyAddress(_deployer()),
            "WithdrawalPolicy does not match expected address"
        );
        _logDeployment("WithdrawalPolicy", WITHDRAWAL_POLICY_SALT_SEED, withdrawalPolicy);
        return withdrawalPolicy;
    }

    function _deployIouToken() internal returns (address) {
        address iouToken = _deploy_create3({
            namespacedSaltSeed: IOU_TOKEN_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(type(IouToken).creationCode, abi.encode(getIouTokenManagerAddress(_deployer())))
        });
        require(iouToken == getIouTokenAddress(_deployer()), "IouToken does not match expected address");
        _logDeployment("IouToken", IOU_TOKEN_SALT_SEED, iouToken);
        return iouToken;
    }

    function _deployIouTokenManager() internal returns (address) {
        address implementation = address(
            new IouTokenManager({
                iouToken: getIouTokenAddress(_deployer()),
                chainGateway: getGatewayAddress(_deployer()),
                vault: address(0),
                transferHelper: getTransferHelperAddress(_deployer()),
                isAccountingChain: false
            })
        );
        _logDeployment("IouTokenManager::Implementation", "", implementation);
        address iouTokenManager = _deployTransparentProxy_create3({
            namespacedSaltSeed: IOU_TOKEN_MANAGER_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: IOU_TOKEN_MANAGER_PROXY_ADMIN_OWNER,
            initCalldata: ""
        });
        require(
            iouTokenManager == getIouTokenManagerAddress(_deployer()), "IouTokenManager does not match expected address"
        );
        _logDeployment("IouTokenManager", IOU_TOKEN_MANAGER_SALT_SEED, iouTokenManager);
        return iouTokenManager;
    }

    function _deployAllocator() internal returns (address) {
        address implementation = address(
            new Allocator({
                assetRegistry: getAssetRegistryAddress(_deployer()),
                depositor: ALLOCATOR_DEPOSITOR,
                withdrawer: ALLOCATOR_WITHDRAWER,
                priceOracle: getPriceOracleAddress(_deployer()),
                transferHelper: getTransferHelperAddress(_deployer()),
                maxStrategiesPerAsset: MAX_STRATEGIES_PER_ASSET
            })
        );
        _logDeployment("Allocator::Implementation", "", implementation);
        address allocator = _deployTransparentProxy_create3({
            namespacedSaltSeed: ALLOCATOR_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: ALLOCATOR_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(Allocator.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(allocator == getAllocatorAddress(_deployer()), "Allocator does not match expected address");
        _logDeployment("Allocator", ALLOCATOR_SALT_SEED, allocator);
        return allocator;
    }

    function _deployGateway() internal returns (address) {
        address implementation = address(
            new EarningChainGateway({
                accountingChainId: ACCOUNTING_CHAIN_ID,
                allocator: getAllocatorAddress(_deployer()),
                priceOracle: getPriceOracleAddress(_deployer()),
                iouTokenManager: getIouTokenManagerAddress(_deployer()),
                transferHelper: getTransferHelperAddress(_deployer()),
                withdrawalPolicy: getWithdrawalPolicyAddress(_deployer())
            })
        );
        _logDeployment("EarningChainGateway::Implementation", "", implementation);
        address gateway = _deployTransparentProxy_create3({
            namespacedSaltSeed: GATEWAY_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: GATEWAY_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(EarningChainGateway.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(gateway == getGatewayAddress(_deployer()), "Gateway does not match expected address");
        _logDeployment("EarningChainGateway", GATEWAY_SALT_SEED, gateway);
        return gateway;
    }

    function _deploySwapper() internal returns (address) {
        address swapper = _deploy_create3({
            namespacedSaltSeed: SWAPPER_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(type(Swapper).creationCode, abi.encode(getAllocatorAddress(_deployer())))
        });
        require(swapper == getSwapperAddress(_deployer()), "Swapper does not match expected address");
        _logDeployment("Swapper", SWAPPER_SALT_SEED, swapper);
        return swapper;
    }

    function _deployCcipAdapter() internal returns (address) {
        address ccipAdapter = _deploy_create3({
            namespacedSaltSeed: CCIP_ADAPTER_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(CcipAdapter).creationCode,
                abi.encode(
                    getAccessManagerAddress(_deployer()),
                    getGatewayAddress(_deployer()),
                    CCIP_ROUTER_ADDRESS,
                    getTransferHelperAddress(_deployer()),
                    getAssetRegistryAddress(_deployer())
                )
            )
        });
        require(ccipAdapter == getCcipAdapterAddress(_deployer()), "CcipAdapter does not match expected address");
        _logDeployment("CcipAdapter", CCIP_ADAPTER_SALT_SEED, ccipAdapter);
        return ccipAdapter;
    }

    function _deployPriceOracle() internal returns (address) {
        address implementation = address(new PriceOracle(PRICE_ORACLE_MIN_VALID_PRICE_RAY));
        _logDeployment("PriceOracle::Implementation", "", implementation);
        address priceOracle = _deployTransparentProxy_create3({
            namespacedSaltSeed: PRICE_ORACLE_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: PRICE_ORACLE_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(PriceOracle.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(priceOracle == getPriceOracleAddress(_deployer()), "PriceOracle does not match expected address");
        _logDeployment("PriceOracle", PRICE_ORACLE_SALT_SEED, priceOracle);
        return priceOracle;
    }

    function _deployEarningChainStateProvider() internal returns (address) {
        address earningChainStateProvider = _deploy_create3({
            namespacedSaltSeed: EARNING_CHAIN_STATE_PROVIDER_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(EarningChainStateProvider).creationCode, abi.encode(getGatewayAddress(_deployer()))
            )
        });
        require(
            earningChainStateProvider == getEarningChainStateProviderAddress(_deployer()),
            "EarningChainStateProvider does not match expected address"
        );
        _logDeployment("EarningChainStateProvider", EARNING_CHAIN_STATE_PROVIDER_SALT_SEED, earningChainStateProvider);
        return earningChainStateProvider;
    }

    function _setupPriceOracleAdapters() internal {
        PriceOracle priceOracle = PriceOracle(getPriceOracleAddress(_deployer()));

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

        address usdtAdapter = address(
            new ChainlinkPriceOracleAdapter(USDT, CHAINLINK_USDT_USD_DATA_FEED, CHAINLINK_PRICE_ORACLE_HEARTBEAT)
        );
        _logDeployment("ChainlinkPriceOracleAdapter::USDT", "", usdtAdapter);
        priceOracle.setOracleAdapterForAsset(USDT, usdtAdapter);
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal virtual override {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/earning.json", string.concat(".", name));
    }
}
