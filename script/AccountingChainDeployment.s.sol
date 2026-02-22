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
import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {StableVault} from "src/core/accounting/StableVault.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {ChainlinkL2ChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkL2ChainBalanceOracleAdapter.sol";
import {ChainlinkL2PriceOracleAdapter} from "src/oracles/price/ChainlinkL2PriceOracleAdapter.sol";
import {AggregatorV3Interface} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";
import {MockBundleFeed} from "test/mocks/MockBundleFeed.sol";
import {MockSequencerUptimeFeed} from "test/mocks/MockSequencerUptimeFeed.sol";

contract AccountingChainDeployment is
    Create3Deployment,
    AccessManagerAccountingChainSetup,
    ATokenVaultDeployment,
    Script
{
    using Strings for address;

    address[] internal _deployedATokenVaults;

    uint256 constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    uint256 constant DEFAULT_SUB_VAULT_PER_SECOND_RATE = 1000000001243680656318820313; // ~4% APY
    uint256 constant DEFAULT_MAX_ACTIVE_SUB_VAULTS = 201;
    uint8 constant MAX_STRATEGIES_PER_ASSET = 15;
    uint8 constant STRATEGY_MAX_SLIPPAGE_AMOUNT = 10; // 10 wei

    address immutable PROXY_ADMIN_OWNER = getAccessManagerAddress(_deployer());
    address immutable STABLE_VAULT_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable ALLOCATOR_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable WITHDRAWAL_POLICY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable ASSET_REGISTRY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable GATEWAY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable IOU_TOKEN_MANAGER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable FUNDS_HANDLER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable PRICE_ORACLE_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable CHAIN_BALANCE_ORACLE_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;

    address immutable ACCESS_MANAGER_ADMIN = _deployer();
    address immutable TREASURY = HIGH_THRESHOLD_MULTISIG_ADMIN_PROFILE;

    address immutable ALLOCATOR_DEPOSITOR = getFundsHandlerAddress(_deployer());
    address immutable ALLOCATOR_WITHDRAWER = getFundsHandlerAddress(_deployer());

    // ERC20s on Arbitrum
    address GHO = address(0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33);
    address USDC = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address USDT = address(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);

    // Standard
    address constant CHAINLINK_GHO_USD_DATA_FEED = address(0x3c786e934F23375Ca345C9b8D5aD54838796E8e7);
    // Standard
    address constant CHAINLINK_USDC_USD_DATA_FEED = address(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3);
    // Standard
    address constant CHAINLINK_USDT_USD_DATA_FEED = address(0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7);

    // Ethereum mainnet
    uint256 constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint64 constant ETHEREUM_MAINNET_CCIP_SELECTOR = 5009297550715157269;

    uint256 constant EARNING_CHAIN_ID = ETHEREUM_MAINNET_CHAIN_ID;

    uint256 constant PRICE_ORACLE_MIN_VALID_PRICE_RAY = 0.99e27; // TODO: Revisit min valid price
    uint256 constant CHAINLINK_PRICE_ORACLE_HEARTBEAT = 24 hours; // TODO: Revisit heartbeat

    uint256 constant CHAINLINK_CHAIN_BALANCE_ORACLE_HEARTBEAT = 24 hours; // TODO: Revisit heartbeat

    // TODO: VNet only – replace with the real Chainlink Bundle Aggregator Proxy address for prod.
    address internal _chainlinkBundleAggregatorProxy;

    // TODO: VNet only – replace with the real Chainlink L2 Sequencer Uptime Feed address for prod.
    address internal _sequencerUptimeFeed;

    // Set to Arbitrum CCIP Router address
    address constant CCIP_ROUTER_ADDRESS = address(0x141fa059441E0ca23ce184B6A78bafD2A517DdE8);

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

        // TODO: VNet only – MockBundleFeed is deployed instead. Re-enable validation for prod with
        // the real Chainlink Bundle Aggregator Proxy address.
        // require(
        //     CHAINLINK_CHAIN_BALANCE_BUNDLE_AGGREGATOR_PROXY != address(0), "Chainlink bundle aggregator proxy not
        // set" );
        // IBundleBaseAggregator(CHAINLINK_CHAIN_BALANCE_BUNDLE_AGGREGATOR_PROXY).latestBundle();

        // Validate CCIP router
        require(
            IRouterClient(CCIP_ROUTER_ADDRESS).isChainSupported(ETHEREUM_MAINNET_CCIP_SELECTOR),
            "CCIP Router does not support earning chain"
        );
    }

    function _deployContracts() internal {
        _deployMockBundleFeed(); // TODO: VNet only – remove for prod and use real Chainlink address.
        _deployMockSequencerUptimeFeed(); // TODO: VNet only – remove for prod and use real Chainlink address.
        _deployTransferHelper();
        _deployAccessManager();
        _deployAssetRegistry();
        _deployWithdrawalPolicy();
        _deployIouToken();
        _deployIouTokenManager();
        _deployPriceOracle();
        _deployChainBalanceOracle();
        _deployStableVault();
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
        _setupFundsHandler();
        _setupWithdrawalPolicy();
        _setupAccessManager(_deployer());
        _setupPriceOracleAdapters();
        _setupChainBalanceOracleAdapters();
    }

    function _accessManager() internal view virtual override returns (address) {
        return getAccessManagerAddress(_deployer());
    }

    function _setupBridgeAdapters() internal {
        // NOTE: This assumes adapters of same type are having the same address on all chains.
        address localCcipAdapter = getCcipAdapterAddress(_deployer());
        address mainnetCcipAdapter = localCcipAdapter;

        IAccountingChainGateway gateway = IAccountingChainGateway(getGatewayAddress(_deployer()));

        uint256 mainnetChainId = ETHEREUM_MAINNET_CHAIN_ID;
        uint64 mainnetCcipChainSelector = ETHEREUM_MAINNET_CCIP_SELECTOR;

        // GHO uses CCIP Adapter
        gateway.addBridgeAdapter(GHO, mainnetChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(GHO, mainnetChainId, localCcipAdapter);

        // USDC uses CCIP Adapter
        gateway.addBridgeAdapter(USDC, mainnetChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(USDC, mainnetChainId, localCcipAdapter);

        // USDT uses CCIP Adapter
        gateway.addBridgeAdapter(USDT, mainnetChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(USDT, mainnetChainId, localCcipAdapter);

        // Message uses CCIP Adapter
        address messageOnly = address(0);
        gateway.addBridgeAdapter(messageOnly, mainnetChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(messageOnly, mainnetChainId, localCcipAdapter);

        ICcipBridgeAdapter(localCcipAdapter).setChainSelector(mainnetChainId, mainnetCcipChainSelector);
        ICcipBridgeAdapter(localCcipAdapter).setDestinationChainAdapter(mainnetChainId, mainnetCcipAdapter);
    }

    function _setupAllocator() internal {
        IAllocator allocator = IAllocator(getAllocatorAddress(_deployer()));

        // Aave V3 Arbitrum PoolAddressesProvider
        address poolAddressProvider = address(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);

        address ghoYieldStrategy = _deployATokenVault(GHO, poolAddressProvider, _deployer());
        allocator.addStrategy(GHO, ghoYieldStrategy, STRATEGY_MAX_SLIPPAGE_AMOUNT);
        allocator.setDefaultStrategy(GHO, ghoYieldStrategy);
        _deployedATokenVaults.push(ghoYieldStrategy);
        _logDeployment("GHO aTokenVault", "create2:keccak256(abi.encode(ghoAddress))", ghoYieldStrategy);

        address usdcYieldStrategy = _deployATokenVault(USDC, poolAddressProvider, _deployer());
        allocator.addStrategy(USDC, usdcYieldStrategy, STRATEGY_MAX_SLIPPAGE_AMOUNT);
        allocator.setDefaultStrategy(USDC, usdcYieldStrategy);
        _deployedATokenVaults.push(usdcYieldStrategy);
        _logDeployment("USDC aTokenVault", "create2:keccak256(abi.encode(usdcAddress))", usdcYieldStrategy);

        address usdtYieldStrategy = _deployATokenVault(USDT, poolAddressProvider, _deployer());
        allocator.addStrategy(USDT, usdtYieldStrategy, STRATEGY_MAX_SLIPPAGE_AMOUNT);
        allocator.setDefaultStrategy(USDT, usdtYieldStrategy);
        _deployedATokenVaults.push(usdtYieldStrategy);
        _logDeployment("USDT aTokenVault", "create2:keccak256(abi.encode(usdtAddress))", usdtYieldStrategy);
    }

    function _aTokenVaultAddresses() internal view virtual override returns (address[] memory) {
        return _deployedATokenVaults;
    }

    function _setupFundsHandler() internal {
        IFundsHandler fundsHandler = IFundsHandler(getFundsHandlerAddress(_deployer()));
        fundsHandler.addEarningChain(EARNING_CHAIN_ID);
    }

    function _setupWithdrawalPolicy() internal {
        WithdrawalPolicy withdrawalPolicy = WithdrawalPolicy(getWithdrawalPolicyAddress(_deployer()));
        withdrawalPolicy.setDefaultFeeBps(50); // 0.5% – TODO: VNet only – reconsider default fee for prod
        withdrawalPolicy.setSigner(address(0x8eFCe8C8cF3d1B198D95B3067EcF43Fb0A1039e2), true); // TODO: Set prod signer
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
        address implementation = address(new WithdrawalPolicy(getStableVaultAddress(_deployer())));
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
                vault: getStableVaultAddress(_deployer()),
                transferHelper: getTransferHelperAddress(_deployer()),
                isAccountingChain: true
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

    function _deployStableVault() internal returns (address) {
        address implementation = address(
            new StableVault({
                maxValidPerSecondRate: DEFAULT_MAX_PER_SECOND_RATE,
                assetRegistry: getAssetRegistryAddress(_deployer()),
                iouTokenManager: getIouTokenManagerAddress(_deployer()),
                fundsHandler: getFundsHandlerAddress(_deployer()),
                transferHelper: getTransferHelperAddress(_deployer()),
                withdrawalPolicy: getWithdrawalPolicyAddress(_deployer()),
                priceOracle: getPriceOracleAddress(_deployer()),
                maxActiveSubVaults: DEFAULT_MAX_ACTIVE_SUB_VAULTS
            })
        );
        _logDeployment("StableVault::Implementation", "", implementation);
        address stableVault = _deployTransparentProxy_create3({
            namespacedSaltSeed: STABLE_VAULT_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: STABLE_VAULT_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(
                StableVault.initialize,
                (getAccessManagerAddress(_deployer()), TREASURY, DEFAULT_SUB_VAULT_PER_SECOND_RATE)
            )
        });
        require(stableVault == getStableVaultAddress(_deployer()), "StableVault does not match expected address");
        _logDeployment("StableVault", STABLE_VAULT_SALT_SEED, stableVault);
        return stableVault;
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

    function _deployFundsHandler() internal returns (address) {
        address implementation = address(
            new FundsHandler({
                stableVault: getStableVaultAddress(_deployer()),
                gateway: getGatewayAddress(_deployer()),
                allocator: getAllocatorAddress(_deployer()),
                priceOracle: getPriceOracleAddress(_deployer()),
                transferHelper: getTransferHelperAddress(_deployer()),
                chainBalanceOracle: getChainBalanceOracleAddress(_deployer())
            })
        );
        _logDeployment("FundsHandler::Implementation", "", implementation);
        address fundsHandler = _deployTransparentProxy_create3({
            namespacedSaltSeed: FUNDS_HANDLER_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: FUNDS_HANDLER_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(FundsHandler.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(fundsHandler == getFundsHandlerAddress(_deployer()), "FundsHandler does not match expected address");
        _logDeployment("FundsHandler", FUNDS_HANDLER_SALT_SEED, fundsHandler);
        return fundsHandler;
    }

    function _deployGateway() internal returns (address) {
        address implementation = address(
            new AccountingChainGateway({
                fundsHandler: getFundsHandlerAddress(_deployer()),
                iouTokenManager: getIouTokenManagerAddress(_deployer()),
                chainBalanceOracle: getChainBalanceOracleAddress(_deployer())
            })
        );
        _logDeployment("AccountingChainGateway::Implementation", "", implementation);
        address gateway = _deployTransparentProxy_create3({
            namespacedSaltSeed: GATEWAY_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: GATEWAY_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(AccountingChainGateway.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(gateway == getGatewayAddress(_deployer()), "Gateway does not match expected address");
        _logDeployment("AccountingChainGateway", GATEWAY_SALT_SEED, gateway);
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

    function _deployChainBalanceOracle() internal returns (address) {
        address implementation = address(new ChainBalanceOracle());
        _logDeployment("ChainBalanceOracle::Implementation", "", implementation);
        address chainBalanceOracle = _deployTransparentProxy_create3({
            namespacedSaltSeed: CHAIN_BALANCE_ORACLE_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: CHAIN_BALANCE_ORACLE_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(ChainBalanceOracle.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(
            chainBalanceOracle == getChainBalanceOracleAddress(_deployer()),
            "ChainBalanceOracle does not match expected address"
        );
        _logDeployment("ChainBalanceOracle", CHAIN_BALANCE_ORACLE_SALT_SEED, chainBalanceOracle);
        return chainBalanceOracle;
    }

    // TODO: VNet only – remove for prod and use the real Chainlink Bundle Aggregator Proxy address.
    function _deployMockBundleFeed() internal {
        _chainlinkBundleAggregatorProxy = address(new MockBundleFeed());
        _logDeployment("MockBundleFeed", "", _chainlinkBundleAggregatorProxy);
    }

    // TODO: VNet only – remove for prod and use the real Chainlink L2 Sequencer Uptime Feed address.
    function _deployMockSequencerUptimeFeed() internal {
        _sequencerUptimeFeed = address(new MockSequencerUptimeFeed());
        _logDeployment("MockSequencerUptimeFeed", "", _sequencerUptimeFeed);
    }

    function _setupPriceOracleAdapters() internal {
        PriceOracle priceOracle = PriceOracle(getPriceOracleAddress(_deployer()));

        address ghoAdapter = address(
            new ChainlinkL2PriceOracleAdapter(
                GHO, CHAINLINK_GHO_USD_DATA_FEED, CHAINLINK_PRICE_ORACLE_HEARTBEAT, _sequencerUptimeFeed
            )
        );
        _logDeployment("ChainlinkL2PriceOracleAdapter::GHO", "", ghoAdapter);
        priceOracle.setOracleAdapterForAsset(GHO, ghoAdapter);

        address usdcAdapter = address(
            new ChainlinkL2PriceOracleAdapter(
                USDC, CHAINLINK_USDC_USD_DATA_FEED, CHAINLINK_PRICE_ORACLE_HEARTBEAT, _sequencerUptimeFeed
            )
        );
        _logDeployment("ChainlinkL2PriceOracleAdapter::USDC", "", usdcAdapter);
        priceOracle.setOracleAdapterForAsset(USDC, usdcAdapter);

        address usdtAdapter = address(
            new ChainlinkL2PriceOracleAdapter(
                USDT, CHAINLINK_USDT_USD_DATA_FEED, CHAINLINK_PRICE_ORACLE_HEARTBEAT, _sequencerUptimeFeed
            )
        );
        _logDeployment("ChainlinkL2PriceOracleAdapter::USDT", "", usdtAdapter);
        priceOracle.setOracleAdapterForAsset(USDT, usdtAdapter);
    }

    function _setupChainBalanceOracleAdapters() internal {
        address adapter = address(
            new ChainlinkL2ChainBalanceOracleAdapter(
                EARNING_CHAIN_ID,
                _chainlinkBundleAggregatorProxy, // TODO: VNet only – use
                // CHAINLINK_CHAIN_BALANCE_BUNDLE_AGGREGATOR_PROXY for prod
                CHAINLINK_CHAIN_BALANCE_ORACLE_HEARTBEAT,
                _sequencerUptimeFeed // TODO: VNet only – use real Chainlink L2 Sequencer Uptime Feed for prod
            )
        );
        _logDeployment("ChainlinkL2ChainBalanceOracleAdapter", "", adapter);
        ChainBalanceOracle(getChainBalanceOracleAddress(_deployer()))
            .setChainBalanceOracleAdapter(EARNING_CHAIN_ID, adapter);
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal virtual override {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/v0.3/accounting.json", string.concat(".", name));
    }
}
