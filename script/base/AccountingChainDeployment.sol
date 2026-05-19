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

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
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
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {IBundleBaseAggregator} from "src/oracles/balance/ChainlinkChainBalanceOracleAdapter.sol";
import {ChainlinkL2ChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkL2ChainBalanceOracleAdapter.sol";
import {ChainlinkL2PriceOracleAdapter} from "src/oracles/price/ChainlinkL2PriceOracleAdapter.sol";
import {AggregatorV3Interface} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {EarningChainStateSchemaV1, SCHEMA_VERSION} from "src/periphery/EarningChainStateSchemaV1.sol";
import {PolicyRegistry} from "src/periphery/PolicyRegistry.sol";
import {SlippageCoverageVault} from "src/periphery/SlippageCoverageVault.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";
import {FundsBridgingPolicy} from "src/policies/FundsBridgingPolicy.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";
import {Constants} from "src/types/Constants.sol";
import {MockBundleFeed} from "test/mocks/MockBundleFeed.sol";
import {MockSequencerUptimeFeed} from "test/mocks/MockSequencerUptimeFeed.sol";

abstract contract AccountingChainDeployment is
    Create3Deployment,
    AccessManagerAccountingChainSetup,
    ATokenVaultDeployment
{
    using Strings for address;

    address immutable PROXY_ADMIN_OWNER = getAccessManagerAddress(_deployer());
    address immutable STABLE_VAULT_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable ALLOCATOR_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable WITHDRAWAL_EXECUTION_POLICY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
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

    // keccak256("aave.stable-vault.StableVault.policy.deposit")
    bytes32 internal constant DEPOSIT_POLICY_ID = 0x780c69a8d1890ef009c0e82622a8ad8b5fcebdb4655a550589c95587ab9f8737;
    // keccak256("aave.stable-vault.StableVault.policy.withdrawal-execution")
    bytes32 internal constant WITHDRAWAL_EXECUTION_POLICY_ID =
        0x0b31c7380981f7a065b16980994765a46c7c2446175bc97b41109919817f1ca2;
    // keccak256("aave.stable-vault.FundsHandler.policy.bridge")
    bytes32 internal constant BRIDGE_POLICY_ID = 0xe8134dfa9ba78c8f4bc7215c2603da92d80f826e18cf8cf1673b973cae3e6165;

    address internal _chainlinkBundleAggregatorProxy;
    address internal _sequencerUptimeFeed;

    function _gho() internal view returns (address) {
        return _configAddress(".accountingChain.assets.gho");
    }

    function _usdc() internal view returns (address) {
        return _configAddress(".accountingChain.assets.usdc");
    }

    function _usdt() internal view returns (address) {
        return _configAddress(".accountingChain.assets.usdt");
    }

    function run() public {
        _validateExternalAddresses();
        _validateProfileAddresses();
        _validateDeploymentParameters();
        _validateRedemptionLimitConfig(".accountingChain.withdrawalExecutionPolicy");
        vm.startBroadcast(_deployer());
        _deployContracts();
        _setupContracts();
        vm.stopBroadcast();
    }

    function _validateDeploymentParameters() internal view {
        _validateCommonDeploymentParameters();
        require(block.chainid == _configUint(".accountingChain.chainId"), "must deploy on accounting chain");

        uint256 defaultMaxPerSecondRate = _configUint(".accountingChain.defaultMaxPerSecondRate");
        require(defaultMaxPerSecondRate > MathLib.RAY, "defaultMaxPerSecondRate must be > RAY");

        uint256 defaultSubVaultPerSecondRate = _configUint(".accountingChain.defaultSubVaultPerSecondRate");
        require(defaultSubVaultPerSecondRate >= MathLib.RAY, "defaultSubVaultPerSecondRate must be >= RAY");
        require(
            defaultSubVaultPerSecondRate <= defaultMaxPerSecondRate,
            "defaultSubVaultPerSecondRate must be <= defaultMaxPerSecondRate"
        );

        require(_configUint(".accountingChain.defaultMaxActiveSubVaults") > 0, "defaultMaxActiveSubVaults must be > 0");
        require(
            _configUint(".chainlinkChainBalanceOracleHeartbeat") > 0, "chainlinkChainBalanceOracleHeartbeat must be > 0"
        );
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
                .isChainSupported(_configUint64(".earningChain.ccipSelector")),
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
        require(_configAddress(".withdrawalExecutionPolicy.signer") != address(0), "Withdrawal policy signer not set");
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
        _deployPolicyRegistry();
        _deployWithdrawalExecutionPolicy();
        _deployIouToken();
        _deployIouTokenManager();
        _deployPriceOracle();
        _deployChainBalanceOracle();
        _deployStableVault();
        _deployAllocator();
        _deployFundsHandler();
        _deployGateway();
        _deploySlippageCoverageVault();
        _deploySwapper();
        _deployCcipAdapter();
        _deployAdiAdapter();
        _deployDepositPolicy();
        _deployFundsBridgingPolicy();
    }

    function _setupContracts() internal {
        _setupBridgeAdapters();
        _setupAssetRegistry();
        _setupAllocator();
        _setupFundsHandler();
        _setupWithdrawalExecutionPolicy();
        _setupPriceOracleAdapters();
        _setupChainBalanceOracleAdapters();
        _setupDepositPolicy();
        _setupFundsBridgingPolicy();
        _setupSlippageCoverageVault();
        // Enforce required policies are set before the deployer loses ADMIN_ROLE. Otherwise, a missing policy
        // would only surface in prod, where setting is gated by `CRITICAL_DELAY`.
        _assertRequiredPoliciesSet();
        _setupAccessManager(_deployer()); // Must be last – revokes deployer's ADMIN_ROLE
    }

    function _assertRequiredPoliciesSet() private view {
        IPolicyRegistry registry = IPolicyRegistry(getPolicyRegistryAddress(_deployer()));
        require(registry.getPolicy(DEPOSIT_POLICY_ID) != address(0), "missing accounting-chain deposit policy");
        address policyAddress = registry.getPolicy(WITHDRAWAL_EXECUTION_POLICY_ID);
        require(policyAddress != address(0), "missing accounting-chain withdrawal-execution policy");
        require(registry.getPolicy(BRIDGE_POLICY_ID) != address(0), "missing accounting-chain bridge policy");

        WithdrawalExecutionPolicy policy = WithdrawalExecutionPolicy(policyAddress);
        RateLimitBucketLib.Bucket memory bucket = policy.getRedemptionBucket();
        // Strict greater than: seeding at floor leaves the bucket pinned with no headroom for `lower*` during
        // incident response. Force operator headroom by construction.
        require(
            bucket.capacity > policy.getMinRedemptionCapacity(),
            "accounting-chain redemption capacity must exceed floor"
        );
        require(
            bucket.refillRate > policy.getMinRedemptionRefillRate(),
            "accounting-chain redemption refill rate must exceed floor"
        );
    }

    function _accessManager() internal view virtual override returns (address) {
        return getAccessManagerAddress(_deployer());
    }

    function _setupBridgeAdapters() internal {
        // NOTE: This assumes adapters of same type are having the same address on all chains.
        address localCcipAdapter = getCcipAdapterAddress(_deployer());
        address earningChainCcipAdapter = localCcipAdapter;

        IAccountingChainGateway gateway = IAccountingChainGateway(getGatewayAddress(_deployer()));

        uint256 earningChainId = _configUint(".earningChain.chainId");
        uint64 earningChainCcipSelector = _configUint64(".earningChain.ccipSelector");

        // GHO uses CCIP Adapter
        gateway.addBridgeAdapter(_gho(), earningChainId, localCcipAdapter);

        // USDC uses CCIP Adapter
        gateway.addBridgeAdapter(_usdc(), earningChainId, localCcipAdapter);

        // USDT uses CCIP Adapter
        gateway.addBridgeAdapter(_usdt(), earningChainId, localCcipAdapter);

        ICcipBridgeAdapter(localCcipAdapter).setChainSelector(earningChainId, earningChainCcipSelector);
        ICcipBridgeAdapter(localCcipAdapter).setDestinationChainAdapter(earningChainId, earningChainCcipAdapter);

        // Data-only messages use aDI.
        // aDI adapter is registered on the gateway and configured for the earning chain only when the per-chain flag
        // is set. This lets us deploy the adapter without yet routing messages through it.
        if (_isAdiAdapterDeployed()) {
            // NOTE: Assumes the aDI adapter has the same address on the accounting chain (CREATE3 + same
            // deployer/salt).
            address localAdiAdapter = getAdiAdapterAddress(_deployer());
            address earningChainAdiAdapter = localAdiAdapter;
            IBridgeAdapter(localAdiAdapter).setDestinationChainAdapter(earningChainId, earningChainAdiAdapter);
            if (_configBool(".accountingChain.adi.registerOnGateway")) {
                gateway.addBridgeAdapter(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, earningChainId, localAdiAdapter);
            }
        }
    }

    function _setupAllocator() internal {
        IAllocator allocator = IAllocator(getAllocatorAddress(_deployer()));

        address poolAddressProvider = _configAddress(".accountingChain.aaveV3PoolAddressesProvider");

        address ghoYieldStrategy =
            _deployATokenVault(_gho(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        allocator.addStrategy(_gho(), ghoYieldStrategy);

        address usdcYieldStrategy =
            _deployATokenVault(_usdc(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        allocator.addStrategy(_usdc(), usdcYieldStrategy);

        address usdtYieldStrategy =
            _deployATokenVault(_usdt(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        allocator.addStrategy(_usdt(), usdtYieldStrategy);
    }

    function _deployedATokenVaultAddresses() internal view virtual override returns (address[] memory) {
        return _readATokenVaultAddresses(_configString(".accountingChain.deploymentOutputPath"));
    }

    function _aTokenVaultProxyDeployerSaltSeed(address underlying) internal pure override returns (string memory) {
        return getATokenVaultProxyDeployerSaltSeed(underlying);
    }

    function _setupFundsHandler() internal {
        IFundsHandler fundsHandler = IFundsHandler(getFundsHandlerAddress(_deployer()));
        fundsHandler.addEarningChain(_configUint(".earningChain.chainId"));
    }

    function _setupWithdrawalExecutionPolicy() internal {
        WithdrawalExecutionPolicy withdrawalExecutionPolicy =
            WithdrawalExecutionPolicy(getWithdrawalExecutionPolicyAddress(_deployer()));
        withdrawalExecutionPolicy.setDefaultFeeBps(_configUint16(".withdrawalExecutionPolicy.defaultFeeBps"));
        withdrawalExecutionPolicy.addSigner(_configAddress(".withdrawalExecutionPolicy.signer"));

        _initRedemptionLimit(withdrawalExecutionPolicy, ".accountingChain.withdrawalExecutionPolicy.redemptionLimit");

        IPolicyRegistry(getPolicyRegistryAddress(_deployer()))
            .setPolicy(WITHDRAWAL_EXECUTION_POLICY_ID, address(withdrawalExecutionPolicy));
    }

    function _initRedemptionLimit(WithdrawalExecutionPolicy policy, string memory configKey) private {
        uint128 capacity = _configUint128(string.concat(configKey, ".capacity"));
        uint128 refillRate = _configUint128(string.concat(configKey, ".refillRate"));
        policy.raiseRedemptionCapacity(capacity);
        policy.raiseRedemptionRefillRate(refillRate);
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

    function _deployWithdrawalExecutionPolicy() internal returns (address) {
        uint128 minRedemptionCapacity =
            _configUint128(".accountingChain.withdrawalExecutionPolicy.minRedemptionCapacity");
        uint128 minRedemptionRefillRate =
            _configUint128(".accountingChain.withdrawalExecutionPolicy.minRedemptionRefillRate");
        address implementation = address(
            new WithdrawalExecutionPolicy(
                getStableVaultAddress(_deployer()), minRedemptionCapacity, minRedemptionRefillRate
            )
        );
        _logDeployment("WithdrawalExecutionPolicy::Implementation", "", implementation);
        address withdrawalExecutionPolicy = _deployTransparentProxy_create3({
            namespacedSaltSeed: WITHDRAWAL_EXECUTION_POLICY_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: WITHDRAWAL_EXECUTION_POLICY_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(
                WithdrawalExecutionPolicy.initialize, (getAccessManagerAddress(_deployer()), 0)
            )
        });
        require(
            withdrawalExecutionPolicy == getWithdrawalExecutionPolicyAddress(_deployer()),
            "WithdrawalExecutionPolicy does not match expected address"
        );
        _logDeployment("WithdrawalExecutionPolicy", WITHDRAWAL_EXECUTION_POLICY_SALT_SEED, withdrawalExecutionPolicy);
        return withdrawalExecutionPolicy;
    }

    function _deployIouToken() internal returns (address) {
        address iouToken = _deploy_create3({
            namespacedSaltSeed: IOU_TOKEN_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(IouToken).creationCode,
                abi.encode(
                    getIouTokenManagerAddress(_deployer()),
                    _configString(".iouTokenName"),
                    _configString(".iouTokenSymbol")
                )
            )
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
                maxValidPerSecondRate: _configUint(".accountingChain.defaultMaxPerSecondRate"),
                assetRegistry: getAssetRegistryAddress(_deployer()),
                iouTokenManager: getIouTokenManagerAddress(_deployer()),
                fundsHandler: getFundsHandlerAddress(_deployer()),
                transferHelper: getTransferHelperAddress(_deployer()),
                priceOracle: getPriceOracleAddress(_deployer()),
                maxActiveSubVaults: _configUint(".accountingChain.defaultMaxActiveSubVaults"),
                policyRegistry: getPolicyRegistryAddress(_deployer())
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
                    _configUint(".accountingChain.defaultSubVaultPerSecondRate"),
                    _configString(".accountingChain.stableVaultName"),
                    _configString(".accountingChain.stableVaultSymbol")
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
                maxStrategiesPerAsset: _configUint8(".maxStrategiesPerAsset"),
                policyRegistry: getPolicyRegistryAddress(_deployer())
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
                chainBalanceOracle: getChainBalanceOracleAddress(_deployer()),
                policyRegistry: getPolicyRegistryAddress(_deployer())
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

    function _deploySlippageCoverageVault() internal returns (address) {
        address slippageCoverageVault = _deploy_create3({
            namespacedSaltSeed: SLIPPAGE_COVERAGE_VAULT_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(SlippageCoverageVault).creationCode,
                abi.encode(
                    getSwapperAddress(_deployer()),
                    getAccessManagerAddress(_deployer()),
                    _configUint16(".slippageCoverageVault.maxSlippageBps"),
                    _configUint16(".slippageCoverageVault.overrideMaxSlippageBps"),
                    _configBool(".slippageCoverageVault.initialOverrideMode")
                )
            )
        });
        require(
            slippageCoverageVault == getSlippageCoverageVaultAddress(_deployer()),
            "SlippageCoverageVault does not match expected address"
        );
        _logDeployment("SlippageCoverageVault", SLIPPAGE_COVERAGE_VAULT_SALT_SEED, slippageCoverageVault);
        return slippageCoverageVault;
    }

    function _deploySwapper() internal returns (address) {
        address swapper = _deploy_create3({
            namespacedSaltSeed: SWAPPER_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(Swapper).creationCode,
                abi.encode(getAllocatorAddress(_deployer()), getSlippageCoverageVaultAddress(_deployer()))
            )
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

    function _isAdiAdapterDeployed() internal view virtual override returns (bool) {
        return _configAddress(".accountingChain.adi.crossChainController") != address(0);
    }

    function _deployAdiAdapter() internal returns (address) {
        if (!_isAdiAdapterDeployed()) {
            return address(0);
        }
        address adiAdapter = _deploy_create3({
            namespacedSaltSeed: ADI_ADAPTER_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(AdiAdapter).creationCode,
                abi.encode(
                    getAccessManagerAddress(_deployer()),
                    getGatewayAddress(_deployer()),
                    _configAddress(".accountingChain.adi.crossChainController"),
                    getTransferHelperAddress(_deployer())
                )
            )
        });
        require(adiAdapter == getAdiAdapterAddress(_deployer()), "AdiAdapter does not match expected address");
        _logDeployment("AdiAdapter", ADI_ADAPTER_SALT_SEED, adiAdapter);
        return adiAdapter;
    }

    function _deployPriceOracle() internal returns (address) {
        address implementation = address(new PriceOracle(_configUint(".priceOracleMinValidPriceRay")));
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
        uint256 earningChainId = _configUint(".earningChain.chainId");
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
        uint256 heartbeat = _configUint(".chainlinkPriceOracleHeartbeat");

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
        uint256 earningChainId = _configUint(".earningChain.chainId");
        address adapter = address(
            new ChainlinkL2ChainBalanceOracleAdapter(
                earningChainId,
                _chainlinkBundleAggregatorProxy,
                _configUint(".chainlinkChainBalanceOracleHeartbeat"),
                _sequencerUptimeFeed
            )
        );
        _logDeployment("ChainlinkL2ChainBalanceOracleAdapter", "", adapter);
        ChainBalanceOracle(getChainBalanceOracleAddress(_deployer()))
            .setChainBalanceOracleAdapter(earningChainId, adapter);
    }

    function _deployPolicyRegistry() internal returns (address) {
        address policyRegistry = _deploy_create3({
            namespacedSaltSeed: POLICY_REGISTRY_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(PolicyRegistry).creationCode, abi.encode(getAccessManagerAddress(_deployer()))
            )
        });
        require(
            policyRegistry == getPolicyRegistryAddress(_deployer()), "PolicyRegistry does not match expected address"
        );
        _logDeployment("PolicyRegistry", POLICY_REGISTRY_SALT_SEED, policyRegistry);
        return policyRegistry;
    }

    function _deployDepositPolicy() internal returns (address) {
        address depositPolicy = _deploy_create3({
            namespacedSaltSeed: DEPOSIT_POLICY_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(DepositPolicy).creationCode,
                abi.encode(getAccessManagerAddress(_deployer()), getStableVaultAddress(_deployer()))
            )
        });
        require(depositPolicy == getDepositPolicyAddress(_deployer()), "DepositPolicy does not match expected address");
        _logDeployment("DepositPolicy", DEPOSIT_POLICY_SALT_SEED, depositPolicy);
        return depositPolicy;
    }

    function _deployFundsBridgingPolicy() internal returns (address) {
        address fundsBridgingPolicy = _deploy_create3({
            namespacedSaltSeed: FUNDS_BRIDGING_POLICY_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(FundsBridgingPolicy).creationCode,
                abi.encode(getAccessManagerAddress(_deployer()), getFundsHandlerAddress(_deployer()))
            )
        });
        require(
            fundsBridgingPolicy == getFundsBridgingPolicyAddress(_deployer()),
            "FundsBridgingPolicy does not match expected address"
        );
        _logDeployment("FundsBridgingPolicy", FUNDS_BRIDGING_POLICY_SALT_SEED, fundsBridgingPolicy);
        return fundsBridgingPolicy;
    }

    function _setupDepositPolicy() internal {
        DepositPolicy policy = DepositPolicy(getDepositPolicyAddress(_deployer()));

        IPolicyRegistry(getPolicyRegistryAddress(_deployer())).setPolicy(DEPOSIT_POLICY_ID, address(policy));

        _initDepositLimit(policy, _gho(), ".accountingChain.depositPolicy.perAssetLimits.gho");
        _initDepositLimit(policy, _usdc(), ".accountingChain.depositPolicy.perAssetLimits.usdc");
        _initDepositLimit(policy, _usdt(), ".accountingChain.depositPolicy.perAssetLimits.usdt");
    }

    function _initDepositLimit(DepositPolicy policy, address asset, string memory configKey) private {
        uint128 capacity = _configUint128(string.concat(configKey, ".capacity"));
        uint128 refillRate = _configUint128(string.concat(configKey, ".refillRate"));
        policy.raiseDepositCapacity(asset, capacity);
        if (refillRate > 0) {
            policy.raiseDepositRefillRate(asset, refillRate);
        }
    }

    function _setupFundsBridgingPolicy() internal {
        FundsBridgingPolicy policy = FundsBridgingPolicy(getFundsBridgingPolicyAddress(_deployer()));

        IPolicyRegistry(getPolicyRegistryAddress(_deployer())).setPolicy(BRIDGE_POLICY_ID, address(policy));

        uint256 destChainId = _configUint(".earningChain.chainId");
        address bridgeAdapter = getCcipAdapterAddress(_deployer());

        _initBridgingLimit(
            policy, _gho(), destChainId, bridgeAdapter, ".accountingChain.fundsBridgingPolicy.perAssetLimits.gho"
        );
        _initBridgingLimit(
            policy, _usdc(), destChainId, bridgeAdapter, ".accountingChain.fundsBridgingPolicy.perAssetLimits.usdc"
        );
        _initBridgingLimit(
            policy, _usdt(), destChainId, bridgeAdapter, ".accountingChain.fundsBridgingPolicy.perAssetLimits.usdt"
        );
    }

    function _initBridgingLimit(
        FundsBridgingPolicy policy,
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        string memory configKey
    ) private {
        uint128 capacity = _configUint128(string.concat(configKey, ".capacity"));
        uint128 refillRate = _configUint128(string.concat(configKey, ".refillRate"));
        policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, capacity);
        if (refillRate > 0) {
            policy.raiseBridgingRefillRate(asset, destChainId, bridgeAdapter, refillRate);
        }
    }

    function _setupSlippageCoverageVault() internal {
        SlippageCoverageVault vault = SlippageCoverageVault(getSlippageCoverageVaultAddress(_deployer()));
        _ensureNonZeroSlippageCoverageVaultAssetCaps(vault, _gho(), ".slippageCoverageVault.perAssetCaps.gho");
        _ensureNonZeroSlippageCoverageVaultAssetCaps(vault, _usdc(), ".slippageCoverageVault.perAssetCaps.usdc");
        _ensureNonZeroSlippageCoverageVaultAssetCaps(vault, _usdt(), ".slippageCoverageVault.perAssetCaps.usdt");
    }

    function _ensureNonZeroSlippageCoverageVaultAssetCaps(
        SlippageCoverageVault vault,
        address asset,
        string memory configKey
    ) private {
        uint256 pullCapPerTx = _configUint(string.concat(configKey, ".pullCapPerTx"));
        uint128 windowCap = _configUint128(string.concat(configKey, ".windowCap"));
        uint64 windowSeconds = _configUint64(string.concat(configKey, ".windowSeconds"));

        require(pullCapPerTx > 0, "SCV pullCapPerTx must be > 0");
        require(windowCap > 0, "SCV windowCap must be > 0");
        require(windowSeconds > 0, "SCV windowSeconds must be > 0");

        uint256 currentPullCap = vault.getPullCapPerTx(asset);
        if (currentPullCap == 0) {
            vault.raisePullCapPerTx(asset, pullCapPerTx);
        } else {
            require(currentPullCap == pullCapPerTx, "SCV pullCapPerTx mismatch");
        }

        SlippageCoverageVault.Window memory window = vault.getWindow(asset);
        if (window.cap == 0) {
            vault.raiseWindowCap(asset, windowCap);
        } else {
            require(window.cap == windowCap, "SCV windowCap mismatch");
        }

        window = vault.getWindow(asset);
        if (window.windowSeconds == 0) {
            vault.raiseWindowSeconds(asset, windowSeconds);
        } else {
            require(window.windowSeconds == windowSeconds, "SCV windowSeconds mismatch");
        }

        _assertSlippageCoverageVaultCaps(vault, asset, pullCapPerTx, windowCap, windowSeconds);
    }

    function _assertSlippageCoverageVaultCaps(
        SlippageCoverageVault vault,
        address asset,
        uint256 pullCapPerTx,
        uint128 windowCap,
        uint64 windowSeconds
    ) private view {
        require(vault.getPullCapPerTx(asset) == pullCapPerTx, "SCV pullCapPerTx not configured");
        SlippageCoverageVault.Window memory window = vault.getWindow(asset);
        require(window.cap == windowCap, "SCV windowCap not configured");
        require(window.windowSeconds == windowSeconds, "SCV windowSeconds not configured");
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal virtual override {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, _configString(".accountingChain.deploymentOutputPath"), string.concat(".", name));
    }

    function _logATokenVaultDeployments() internal override {
        vm.writeJson(_buildATokenVaultsJson(), _configString(".accountingChain.deploymentOutputPath"), ".aTokenVaults");
    }
}
