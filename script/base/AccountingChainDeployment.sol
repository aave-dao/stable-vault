// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

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
import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {IBundleBaseAggregator} from "src/oracles/balance/ChainlinkChainBalanceOracleAdapter.sol";
import {ChainlinkL2ChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkL2ChainBalanceOracleAdapter.sol";
import {ChainlinkL2PriceOracleAdapter} from "src/oracles/price/ChainlinkL2PriceOracleAdapter.sol";
import {AggregatorV3Interface} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {EarningChainStateSchemaV1, SCHEMA_VERSION} from "src/periphery/EarningChainStateSchemaV1.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";
import {MockBundleFeed} from "test/mocks/MockBundleFeed.sol";
import {MockSequencerUptimeFeed} from "test/mocks/MockSequencerUptimeFeed.sol";

abstract contract AccountingChainDeployment is
    Create3Deployment,
    AccessManagerAccountingChainSetup,
    ATokenVaultDeployment
{
    using Strings for address;

    address[] internal _deployedATokenVaults;

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
    address immutable TREASURY = _getProfile__MainAdmin();

    address immutable ALLOCATOR_DEPOSITOR = getFundsHandlerAddress(_deployer());
    address immutable ALLOCATOR_WITHDRAWER = getFundsHandlerAddress(_deployer());

    address internal _chainlinkBundleAggregatorProxy;
    address internal _sequencerUptimeFeed;

    function _gho() internal view returns (address) {
        return _configAddress(".accountingChain.tokens.gho");
    }

    function _usdc() internal view returns (address) {
        return _configAddress(".accountingChain.tokens.usdc");
    }

    function _usdt() internal view returns (address) {
        return _configAddress(".accountingChain.tokens.usdt");
    }

    function run() public {
        _validateExternalAddresses();
        vm.startBroadcast(_deployer());
        _deployContracts();
        _setupContracts();
        vm.stopBroadcast();
    }

    function _validateExternalAddresses() internal view {
        // Validate ERC20 token addresses
        IERC20(_gho()).balanceOf(_deployer());
        IERC20(_usdc()).balanceOf(_deployer());
        IERC20(_usdt()).balanceOf(_deployer());

        // Validate Chainlink price feed addresses
        address ghoUsdFeed = _configAddress(".accountingChain.chainlinkFeeds.ghoUsd");
        require(ghoUsdFeed != address(0), "Chainlink GHO/USD data feed not set");
        AggregatorV3Interface(ghoUsdFeed).latestRoundData();

        address usdcUsdFeed = _configAddress(".accountingChain.chainlinkFeeds.usdcUsd");
        require(usdcUsdFeed != address(0), "Chainlink USDC/USD data feed not set");
        AggregatorV3Interface(usdcUsdFeed).latestRoundData();

        address usdtUsdFeed = _configAddress(".accountingChain.chainlinkFeeds.usdtUsd");
        require(usdtUsdFeed != address(0), "Chainlink USDT/USD data feed not set");
        AggregatorV3Interface(usdtUsdFeed).latestRoundData();

        // Validate CCIP router
        require(
            IRouterClient(_configAddress(".accountingChain.ccipRouterAddress"))
                .isChainSupported(uint64(vm.parseUint(_configString(".accountingChain.earningChainCcipSelector")))),
            "CCIP Router does not support earning chain"
        );

        // Validate Chainlink bundle feed / sequencer uptime feed
        address bundleFeed = _configAddress(".accountingChain.chainlinkBundleAggregatorProxy");
        if (_configBool(".accountingChain.useMockBundleFeed")) {
            require(bundleFeed == address(0), "Chainlink bundle aggregator proxy must not be set when using mock");
        } else {
            require(bundleFeed != address(0), "Chainlink bundle aggregator proxy not set");
            IBundleBaseAggregator(bundleFeed).latestBundle();
        }
        address sequencerFeed = _configAddress(".accountingChain.sequencerUptimeFeed");
        if (_configBool(".accountingChain.useMockSequencerUptimeFeed")) {
            require(sequencerFeed == address(0), "Sequencer uptime feed must not be set when using mock");
        } else {
            require(sequencerFeed != address(0), "Sequencer uptime feed not set");
            AggregatorV3Interface(sequencerFeed).latestRoundData();
        }

        // Validate Aave V3 pool addresses provider
        require(
            _configAddress(".accountingChain.aaveV3PoolAddressesProvider") != address(0),
            "Aave V3 pool addresses provider not set"
        );

        // Validate withdrawal policy signer
        require(
            _configAddress(".accountingChain.withdrawalPolicy.signer") != address(0), "Withdrawal policy signer not set"
        );
    }

    function _deployContracts() internal {
        if (_configBool(".accountingChain.useMockBundleFeed")) {
            _deployMockBundleFeed();
        } else {
            _chainlinkBundleAggregatorProxy = _configAddress(".accountingChain.chainlinkBundleAggregatorProxy");
        }
        if (_configBool(".accountingChain.useMockSequencerUptimeFeed")) {
            _deployMockSequencerUptimeFeed();
        } else {
            _sequencerUptimeFeed = _configAddress(".accountingChain.sequencerUptimeFeed");
        }
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
        _setupPriceOracleAdapters();
        _setupChainBalanceOracleAdapters();
        _setupAccessManager(_deployer()); // Must be last – revokes deployer's ADMIN_ROLE
    }

    function _accessManager() internal view virtual override returns (address) {
        return getAccessManagerAddress(_deployer());
    }

    function _setupBridgeAdapters() internal {
        // NOTE: This assumes adapters of same type are having the same address on all chains.
        address localCcipAdapter = getCcipAdapterAddress(_deployer());
        address earningChainCcipAdapter = localCcipAdapter;

        IAccountingChainGateway gateway = IAccountingChainGateway(getGatewayAddress(_deployer()));

        uint256 earningChainId = _configUint(".accountingChain.earningChainId");
        uint64 earningChainCcipSelector =
            uint64(vm.parseUint(_configString(".accountingChain.earningChainCcipSelector")));

        // GHO uses CCIP Adapter
        gateway.addBridgeAdapter(_gho(), earningChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(_gho(), earningChainId, localCcipAdapter);

        // USDC uses CCIP Adapter
        gateway.addBridgeAdapter(_usdc(), earningChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(_usdc(), earningChainId, localCcipAdapter);

        // USDT uses CCIP Adapter
        gateway.addBridgeAdapter(_usdt(), earningChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(_usdt(), earningChainId, localCcipAdapter);

        // Message uses CCIP Adapter
        address messageOnly = address(0);
        gateway.addBridgeAdapter(messageOnly, earningChainId, localCcipAdapter);
        gateway.setDefaultBridgeAdapter(messageOnly, earningChainId, localCcipAdapter);

        ICcipBridgeAdapter(localCcipAdapter).setChainSelector(earningChainId, earningChainCcipSelector);
        ICcipBridgeAdapter(localCcipAdapter).setDestinationChainAdapter(earningChainId, earningChainCcipAdapter);
    }

    function _setupAllocator() internal {
        IAllocator allocator = IAllocator(getAllocatorAddress(_deployer()));

        address poolAddressProvider = _configAddress(".accountingChain.aaveV3PoolAddressesProvider");

        address ghoYieldStrategy =
            _deployATokenVault(_gho(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        allocator.addStrategy(
            _gho(), ghoYieldStrategy, uint8(_configUint(".accountingChain.strategyMaxSlippageAmount"))
        );
        allocator.setDefaultStrategy(_gho(), ghoYieldStrategy);
        _deployedATokenVaults.push(ghoYieldStrategy);
        _logDeployment("GHO aTokenVault", "", ghoYieldStrategy);

        address usdcYieldStrategy =
            _deployATokenVault(_usdc(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        allocator.addStrategy(
            _usdc(), usdcYieldStrategy, uint8(_configUint(".accountingChain.strategyMaxSlippageAmount"))
        );
        allocator.setDefaultStrategy(_usdc(), usdcYieldStrategy);
        _deployedATokenVaults.push(usdcYieldStrategy);
        _logDeployment("USDC aTokenVault", "", usdcYieldStrategy);

        address usdtYieldStrategy =
            _deployATokenVault(_usdt(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        allocator.addStrategy(
            _usdt(), usdtYieldStrategy, uint8(_configUint(".accountingChain.strategyMaxSlippageAmount"))
        );
        allocator.setDefaultStrategy(_usdt(), usdtYieldStrategy);
        _deployedATokenVaults.push(usdtYieldStrategy);
        _logDeployment("USDT aTokenVault", "", usdtYieldStrategy);
    }

    function _aTokenVaultAddresses() internal view virtual override returns (address[] memory) {
        return _deployedATokenVaults;
    }

    function _setupFundsHandler() internal {
        IFundsHandler fundsHandler = IFundsHandler(getFundsHandlerAddress(_deployer()));
        fundsHandler.addEarningChain(_configUint(".accountingChain.earningChainId"));
    }

    function _setupWithdrawalPolicy() internal {
        WithdrawalPolicy withdrawalPolicy = WithdrawalPolicy(getWithdrawalPolicyAddress(_deployer()));
        withdrawalPolicy.setDefaultFeeBps(uint16(_configUint(".accountingChain.withdrawalPolicy.defaultFeeBps")));
        withdrawalPolicy.setSigner(_configAddress(".accountingChain.withdrawalPolicy.signer"), true);
    }

    function _setupAssetRegistry() internal {
        IAssetRegistry assetRegistry = IAssetRegistry(getAssetRegistryAddress(_deployer()));
        IAssetRegistry.AssetConfig memory unrestrictedAssetConfig = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        assetRegistry.setAssetConfig(_gho(), unrestrictedAssetConfig);
        assetRegistry.setAssetConfig(_usdc(), unrestrictedAssetConfig);
        assetRegistry.setAssetConfig(_usdt(), unrestrictedAssetConfig);
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
                maxValidPerSecondRate: vm.parseUint(_configString(".accountingChain.defaultMaxPerSecondRate")),
                assetRegistry: getAssetRegistryAddress(_deployer()),
                iouTokenManager: getIouTokenManagerAddress(_deployer()),
                fundsHandler: getFundsHandlerAddress(_deployer()),
                transferHelper: getTransferHelperAddress(_deployer()),
                withdrawalPolicy: getWithdrawalPolicyAddress(_deployer()),
                priceOracle: getPriceOracleAddress(_deployer()),
                maxActiveSubVaults: _configUint(".accountingChain.defaultMaxActiveSubVaults")
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
                (
                    getAccessManagerAddress(_deployer()),
                    TREASURY,
                    vm.parseUint(_configString(".accountingChain.defaultSubVaultPerSecondRate"))
                )
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
                maxStrategiesPerAsset: uint8(_configUint(".accountingChain.maxStrategiesPerAsset"))
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
                    _configAddress(".accountingChain.ccipRouterAddress"),
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
        address implementation =
            address(new PriceOracle(vm.parseUint(_configString(".accountingChain.priceOracleMinValidPriceRay"))));
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

    function _deployMockBundleFeed() internal {
        uint256 earningChainId = _configUint(".accountingChain.earningChainId");
        MockBundleFeed mockBundleFeed = new MockBundleFeed();
        _chainlinkBundleAggregatorProxy = address(mockBundleFeed);
        _logDeployment("MockBundleFeed", "", _chainlinkBundleAggregatorProxy);

        // Seed with valid initial state so ChainBalanceOracle adapter validation passes during setup.
        EarningChainStateSchemaV1.BalanceSnapshot memory snapshot = EarningChainStateSchemaV1.BalanceSnapshot({
            balanceRay: 0, timestamp: block.timestamp, blockNumber: block.number, chainId: earningChainId
        });
        IEarningChainStateProvider.State memory state =
            IEarningChainStateProvider.State({version: SCHEMA_VERSION, data: abi.encode(snapshot)});
        mockBundleFeed.publishState(abi.encode(state));
    }

    function _deployMockSequencerUptimeFeed() internal {
        _sequencerUptimeFeed = address(new MockSequencerUptimeFeed());
        _logDeployment("MockSequencerUptimeFeed", "", _sequencerUptimeFeed);
    }

    function _setupPriceOracleAdapters() internal {
        PriceOracle priceOracle = PriceOracle(getPriceOracleAddress(_deployer()));
        uint256 heartbeat = _configUint(".accountingChain.chainlinkPriceOracleHeartbeat");

        address ghoAdapter = address(
            new ChainlinkL2PriceOracleAdapter(
                _gho(), _configAddress(".accountingChain.chainlinkFeeds.ghoUsd"), heartbeat, _sequencerUptimeFeed
            )
        );
        _logDeployment("ChainlinkL2PriceOracleAdapter::GHO", "", ghoAdapter);
        priceOracle.setOracleAdapterForAsset(_gho(), ghoAdapter);

        address usdcAdapter = address(
            new ChainlinkL2PriceOracleAdapter(
                _usdc(), _configAddress(".accountingChain.chainlinkFeeds.usdcUsd"), heartbeat, _sequencerUptimeFeed
            )
        );
        _logDeployment("ChainlinkL2PriceOracleAdapter::USDC", "", usdcAdapter);
        priceOracle.setOracleAdapterForAsset(_usdc(), usdcAdapter);

        address usdtAdapter = address(
            new ChainlinkL2PriceOracleAdapter(
                _usdt(), _configAddress(".accountingChain.chainlinkFeeds.usdtUsd"), heartbeat, _sequencerUptimeFeed
            )
        );
        _logDeployment("ChainlinkL2PriceOracleAdapter::USDT", "", usdtAdapter);
        priceOracle.setOracleAdapterForAsset(_usdt(), usdtAdapter);
    }

    function _setupChainBalanceOracleAdapters() internal {
        uint256 earningChainId = _configUint(".accountingChain.earningChainId");
        address adapter = address(
            new ChainlinkL2ChainBalanceOracleAdapter(
                earningChainId,
                _chainlinkBundleAggregatorProxy,
                _configUint(".accountingChain.chainlinkChainBalanceOracleHeartbeat"),
                _sequencerUptimeFeed
            )
        );
        _logDeployment("ChainlinkL2ChainBalanceOracleAdapter", "", adapter);
        ChainBalanceOracle(getChainBalanceOracleAddress(_deployer()))
            .setChainBalanceOracleAdapter(earningChainId, adapter);
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal virtual override {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, _configString(".accountingChain.deploymentOutputPath"), string.concat(".", name));
    }
}
