// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerAccountingChainSetup} from "script/base/AccessManagerAccountingChainSetup.sol";
import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {BaseChainDeployment} from "script/base/BaseChainDeployment.sol";
import {logSkip} from "script/libraries/DeploymentLogLib.sol";

import {AccountingChainGateway} from "src/core/accounting/AccountingChainGateway.sol";
import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {StableVault} from "src/core/accounting/StableVault.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {IBundleBaseAggregator} from "src/oracles/balance/ChainlinkChainBalanceOracleAdapter.sol";
import {ChainlinkL2ChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkL2ChainBalanceOracleAdapter.sol";
import {ChainlinkL2PriceOracleAdapter} from "src/oracles/price/ChainlinkL2PriceOracleAdapter.sol";
import {AggregatorV3Interface} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {EarningChainStateSchemaV1, SCHEMA_VERSION} from "src/periphery/EarningChainStateSchemaV1.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";
import {MockBundleFeed} from "test/mocks/MockBundleFeed.sol";
import {MockSequencerUptimeFeed} from "test/mocks/MockSequencerUptimeFeed.sol";

abstract contract AccountingChainDeployment is BaseChainDeployment, AccessManagerAccountingChainSetup {
    address immutable STABLE_VAULT_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable FUNDS_HANDLER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable CHAIN_BALANCE_ORACLE_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;

    address immutable TREASURY = _getProfile__MainAdmin();

    // keccak256("aave.stable-vault.StableVault.policy.deposit")
    bytes32 internal constant DEPOSIT_POLICY_ID = 0x780c69a8d1890ef009c0e82622a8ad8b5fcebdb4655a550589c95587ab9f8737;
    // keccak256("aave.stable-vault.StableVault.policy.withdrawal-execution")
    bytes32 internal constant ACCOUNTING_WITHDRAWAL_EXECUTION_POLICY_ID =
        0x0b31c7380981f7a065b16980994765a46c7c2446175bc97b41109919817f1ca2;
    // keccak256("aave.stable-vault.FundsHandler.policy.bridge")
    bytes32 internal constant ACCOUNTING_BRIDGE_POLICY_ID =
        0xe8134dfa9ba78c8f4bc7215c2603da92d80f826e18cf8cf1673b973cae3e6165;

    address internal _chainlinkBundleAggregatorProxy;
    address internal _sequencerUptimeFeed;

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // BaseChainDeployment hooks.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _chainConfigPrefix() internal pure override returns (string memory) {
        return ".accountingChain";
    }

    function _remoteChainConfigPrefix() internal pure override returns (string memory) {
        return ".earningChain";
    }

    function _chainName() internal pure override returns (string memory) {
        return "accounting-chain";
    }

    function _withdrawalExecutionPolicyId() internal pure override returns (bytes32) {
        return ACCOUNTING_WITHDRAWAL_EXECUTION_POLICY_ID;
    }

    function _bridgePolicyId() internal pure override returns (bytes32) {
        return ACCOUNTING_BRIDGE_POLICY_ID;
    }

    function _withdrawalExecutionPolicyTarget() internal view override returns (address) {
        return getStableVaultAddress(_deployer());
    }

    function _iouTokenManagerVault() internal view override returns (address) {
        return getStableVaultAddress(_deployer());
    }

    function _isAccountingChain() internal pure override returns (bool) {
        return true;
    }

    function _allocatorDepositor() internal view override returns (address) {
        return getFundsHandlerAddress(_deployer());
    }

    function _allocatorWithdrawer() internal view override returns (address) {
        return getFundsHandlerAddress(_deployer());
    }

    function _fundsBridgingPolicyHolder() internal view override returns (address) {
        return getFundsHandlerAddress(_deployer());
    }

    function _validateChainSpecificDeploymentParameters() internal view override {
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

    function _validateChainSpecificExternalAddresses() internal view override {
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
    }

    function _assertChainSpecificRequiredPoliciesSet() internal view override {
        IPolicyRegistry registry = IPolicyRegistry(getPolicyRegistryAddress(_deployer()));
        require(registry.getPolicy(DEPOSIT_POLICY_ID) != address(0), "missing accounting-chain deposit policy");
    }

    function _aTokenVaultUnderlyings() internal view override returns (address[] memory underlyings) {
        underlyings = new address[](3);
        underlyings[0] = _gho();
        underlyings[1] = _usdc();
        underlyings[2] = _usdt();
    }

    function _accessManager()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, BaseChainDeployment)
        returns (address)
    {
        return BaseChainDeployment._accessManager();
    }

    function _shouldRegisterAdiOnGateway()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, BaseChainDeployment)
        returns (bool)
    {
        return BaseChainDeployment._shouldRegisterAdiOnGateway();
    }

    function _adiCrossChainController()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, BaseChainDeployment)
        returns (address)
    {
        return BaseChainDeployment._adiCrossChainController();
    }

    function _deployedATokenVaultAddresses()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, BaseChainDeployment)
        returns (address[] memory)
    {
        return BaseChainDeployment._deployedATokenVaultAddresses();
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr)
        internal
        virtual
        override(AccessManagerBaseSetup, BaseChainDeployment)
    {
        BaseChainDeployment._logDeployment(name, saltSeed, addr);
    }

    function _setup_Profiles() internal virtual override(AccessManagerBaseSetup, AccessManagerAccountingChainSetup) {
        AccessManagerAccountingChainSetup._setup_Profiles();
    }

    function _setup_Targets(address deployer)
        internal
        virtual
        override(AccessManagerBaseSetup, AccessManagerAccountingChainSetup)
    {
        AccessManagerAccountingChainSetup._setup_Targets(deployer);
    }

    function _validateProfileAddresses()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, AccessManagerAccountingChainSetup)
    {
        AccessManagerAccountingChainSetup._validateProfileAddresses();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Deploy / setup orchestration.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _deployContracts() internal override {
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

    function _setupContracts() internal override {
        _setupBridgeAdapters();
        _setupAssetRegistry();
        _setupAllocator();
        _setupChainBalanceOracleAdapters();
        _setupFundsHandler();
        _setupWithdrawalExecutionPolicy();
        _setupPriceOracleAdapters();
        _setupDepositPolicy();
        _setupFundsBridgingPolicy();
        _setupSlippageCoverageVault();
        // Enforce required policies are set before the deployer loses ADMIN_ROLE. Otherwise, a missing policy
        // would only surface in prod, where setting is gated by `CRITICAL_DELAY`.
        _assertRequiredPoliciesSet();
        _setupAccessManager(_deployer()); // Must be last – revokes deployer's ADMIN_ROLE
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Chain-specific deploys.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _deployStableVault() internal returns (address) {
        address predicted = getStableVaultAddress(_deployer());
        bytes memory implCreationCode = abi.encodePacked(
            type(StableVault).creationCode,
            abi.encode(
                _configUint(".accountingChain.defaultMaxPerSecondRate"),
                getAssetRegistryAddress(_deployer()),
                getIouTokenManagerAddress(_deployer()),
                getFundsHandlerAddress(_deployer()),
                getTransferHelperAddress(_deployer()),
                getPriceOracleAddress(_deployer()),
                _configUint(".accountingChain.defaultMaxActiveSubVaults"),
                getPolicyRegistryAddress(_deployer())
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(predicted, implCreationCode, STABLE_VAULT_PROXY_ADMIN_OWNER, "StableVault");
            logSkip("_deployStableVault", "StableVault");
            _logDeployment("StableVault", STABLE_VAULT_SALT_SEED, predicted);
            return predicted;
        }
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
        require(stableVault == predicted, "StableVault does not match expected address");
        _logDeployment("StableVault", STABLE_VAULT_SALT_SEED, stableVault);
        return stableVault;
    }

    function _deployFundsHandler() internal returns (address) {
        address predicted = getFundsHandlerAddress(_deployer());
        bytes memory implCreationCode = abi.encodePacked(
            type(FundsHandler).creationCode,
            abi.encode(
                getStableVaultAddress(_deployer()),
                getGatewayAddress(_deployer()),
                getAllocatorAddress(_deployer()),
                getPriceOracleAddress(_deployer()),
                getTransferHelperAddress(_deployer()),
                getChainBalanceOracleAddress(_deployer()),
                getPolicyRegistryAddress(_deployer())
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(
                predicted, implCreationCode, FUNDS_HANDLER_PROXY_ADMIN_OWNER, "FundsHandler"
            );
            logSkip("_deployFundsHandler", "FundsHandler");
            _logDeployment("FundsHandler", FUNDS_HANDLER_SALT_SEED, predicted);
            return predicted;
        }
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
        require(fundsHandler == predicted, "FundsHandler does not match expected address");
        _logDeployment("FundsHandler", FUNDS_HANDLER_SALT_SEED, fundsHandler);
        return fundsHandler;
    }

    function _deployGateway() internal returns (address) {
        address predicted = getGatewayAddress(_deployer());
        bytes memory implCreationCode = abi.encodePacked(
            type(AccountingChainGateway).creationCode,
            abi.encode(
                getFundsHandlerAddress(_deployer()),
                getIouTokenManagerAddress(_deployer()),
                getChainBalanceOracleAddress(_deployer())
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(
                predicted, implCreationCode, GATEWAY_PROXY_ADMIN_OWNER, "AccountingChainGateway"
            );
            logSkip("_deployGateway", "AccountingChainGateway");
            _logDeployment("AccountingChainGateway", GATEWAY_SALT_SEED, predicted);
            return predicted;
        }
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
        require(gateway == predicted, "Gateway does not match expected address");
        _logDeployment("AccountingChainGateway", GATEWAY_SALT_SEED, gateway);
        return gateway;
    }

    function _deployChainBalanceOracle() internal returns (address) {
        address predicted = getChainBalanceOracleAddress(_deployer());
        bytes memory implCreationCode = type(ChainBalanceOracle).creationCode;
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(
                predicted, implCreationCode, CHAIN_BALANCE_ORACLE_PROXY_ADMIN_OWNER, "ChainBalanceOracle"
            );
            logSkip("_deployChainBalanceOracle", "ChainBalanceOracle");
            _logDeployment("ChainBalanceOracle", CHAIN_BALANCE_ORACLE_SALT_SEED, predicted);
            return predicted;
        }
        address implementation = address(new ChainBalanceOracle());
        _logDeployment("ChainBalanceOracle::Implementation", "", implementation);
        address chainBalanceOracle = _deployTransparentProxy_create3({
            namespacedSaltSeed: CHAIN_BALANCE_ORACLE_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: CHAIN_BALANCE_ORACLE_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(ChainBalanceOracle.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(chainBalanceOracle == predicted, "ChainBalanceOracle does not match expected address");
        _logDeployment("ChainBalanceOracle", CHAIN_BALANCE_ORACLE_SALT_SEED, chainBalanceOracle);
        return chainBalanceOracle;
    }

    function _deployMockBundleFeed() internal {
        address predicted = getMockBundleFeedAddress(_deployer());
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedRuntimeCode(predicted, keccak256(type(MockBundleFeed).runtimeCode), "MockBundleFeed");
            logSkip("_deployMockBundleFeed", "MockBundleFeed");
            _chainlinkBundleAggregatorProxy = predicted;
            _logDeployment("MockBundleFeed", MOCK_BUNDLE_FEED_SALT_SEED, predicted);
        } else {
            address deployed = _deploy_create3({
                namespacedSaltSeed: MOCK_BUNDLE_FEED_SALT_SEED,
                deployer: _deployer(),
                initCode: abi.encodePacked(type(MockBundleFeed).creationCode)
            });
            require(deployed == predicted, "MockBundleFeed does not match expected address");
            _chainlinkBundleAggregatorProxy = deployed;
            _logDeployment("MockBundleFeed", MOCK_BUNDLE_FEED_SALT_SEED, deployed);
        }

        // Seed with valid initial state so ChainBalanceOracle adapter validation passes during setup. This is a
        // separate tx from the deploy above, so it needs its own idempotency guard.
        /// @custom:tx-already-executed-check Empty `latestBundle()` means publishState has not been called yet on this
        /// MockBundleFeed; otherwise a prior run already seeded it.
        if (MockBundleFeed(predicted).latestBundle().length == 0) {
            uint256 earningChainId = _configUint(".earningChain.chainId");
            EarningChainStateSchemaV1.BalanceSnapshot memory snapshot = EarningChainStateSchemaV1.BalanceSnapshot({
                balanceRay: 0, timestamp: block.timestamp, blockNumber: block.number, chainId: earningChainId
            });
            IEarningChainStateProvider.State memory state =
                IEarningChainStateProvider.State({version: SCHEMA_VERSION, data: abi.encode(snapshot)});
            MockBundleFeed(predicted).publishState(abi.encode(state));
        } else {
            logSkip("_deployMockBundleFeed", "MockBundleFeed state already seeded");
        }
    }

    function _deployMockSequencerUptimeFeed() internal {
        address predicted = getMockSequencerUptimeFeedAddress(_deployer());
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedRuntimeCode(
                predicted, keccak256(type(MockSequencerUptimeFeed).runtimeCode), "MockSequencerUptimeFeed"
            );
            logSkip("_deployMockSequencerUptimeFeed", "MockSequencerUptimeFeed");
            _sequencerUptimeFeed = predicted;
            _logDeployment("MockSequencerUptimeFeed", MOCK_SEQUENCER_UPTIME_FEED_SALT_SEED, predicted);
            return;
        }
        address deployed = _deploy_create3({
            namespacedSaltSeed: MOCK_SEQUENCER_UPTIME_FEED_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(type(MockSequencerUptimeFeed).creationCode)
        });
        require(deployed == predicted, "MockSequencerUptimeFeed does not match expected address");
        _sequencerUptimeFeed = deployed;
        _logDeployment("MockSequencerUptimeFeed", MOCK_SEQUENCER_UPTIME_FEED_SALT_SEED, deployed);
    }

    function _deployDepositPolicy() internal returns (address) {
        address predicted = getDepositPolicyAddress(_deployer());
        bytes memory initCode = abi.encodePacked(
            type(DepositPolicy).creationCode,
            abi.encode(getAccessManagerAddress(_deployer()), getStableVaultAddress(_deployer()))
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(predicted, initCode, "DepositPolicy");
            logSkip("_deployDepositPolicy", "DepositPolicy");
            _logDeployment("DepositPolicy", DEPOSIT_POLICY_SALT_SEED, predicted);
            return predicted;
        }
        address depositPolicy =
            _deploy_create3({namespacedSaltSeed: DEPOSIT_POLICY_SALT_SEED, deployer: _deployer(), initCode: initCode});
        require(depositPolicy == predicted, "DepositPolicy does not match expected address");
        _logDeployment("DepositPolicy", DEPOSIT_POLICY_SALT_SEED, depositPolicy);
        return depositPolicy;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Chain-specific setups.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupFundsHandler() internal {
        FundsHandler fundsHandler = FundsHandler(getFundsHandlerAddress(_deployer()));
        uint256 earningChainId = _configUint(".earningChain.chainId");
        uint256[] memory existing = fundsHandler.getEarningChainIds();
        for (uint256 i = 0; i < existing.length; i++) {
            if (existing[i] == earningChainId) {
                /// @custom:tx-already-executed-check Earning chain id is already registered on FundsHandler.
                logSkip("_setupFundsHandler", "earning chain already added to FundsHandler");
                return;
            }
        }
        fundsHandler.addEarningChain(earningChainId);
    }

    function _setupPriceOracleAdapters() internal {
        PriceOracle priceOracle = PriceOracle(getPriceOracleAddress(_deployer()));
        uint256 heartbeat = _configUint(".chainlinkPriceOracleHeartbeat");

        _wireChainlinkL2PriceOracleAdapter(
            priceOracle, _gho(), _configAddress(".accountingChain.chainlinkFeeds.ghoUsd"), heartbeat, "GHO"
        );
        _wireChainlinkL2PriceOracleAdapter(
            priceOracle, _usdc(), _configAddress(".accountingChain.chainlinkFeeds.usdcUsd"), heartbeat, "USDC"
        );
        _wireChainlinkL2PriceOracleAdapter(
            priceOracle, _usdt(), _configAddress(".accountingChain.chainlinkFeeds.usdtUsd"), heartbeat, "USDT"
        );
    }

    function _wireChainlinkL2PriceOracleAdapter(
        PriceOracle priceOracle,
        address asset,
        address feed,
        uint256 heartbeat,
        string memory assetSymbol
    ) private {
        string memory saltSeed = getChainlinkL2PriceOracleAdapterSaltSeed(asset);
        address predicted = getChainlinkL2PriceOracleAdapterAddress(asset, _deployer());
        bytes memory initCode = abi.encodePacked(
            type(ChainlinkL2PriceOracleAdapter).creationCode, abi.encode(asset, feed, heartbeat, _sequencerUptimeFeed)
        );
        address adapter;
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(
                predicted, initCode, string.concat("ChainlinkL2PriceOracleAdapter::", assetSymbol)
            );
            adapter = predicted;
            logSkip(
                "_wireChainlinkL2PriceOracleAdapter",
                string.concat("ChainlinkL2PriceOracleAdapter for ", assetSymbol, " deployed")
            );
        } else {
            adapter = _deploy_create3({namespacedSaltSeed: saltSeed, deployer: _deployer(), initCode: initCode});
            require(adapter == predicted, "ChainlinkL2PriceOracleAdapter does not match expected address");
        }
        _logDeployment(string.concat("ChainlinkL2PriceOracleAdapter::", assetSymbol), saltSeed, adapter);
        /// @custom:tx-already-executed-check Skip when the price oracle is already pointing at this adapter for the
        /// asset.
        if (priceOracle.getOracleAdapterForAsset(asset) != adapter) {
            priceOracle.setOracleAdapterForAsset(asset, adapter);
        } else {
            logSkip(
                "_wireChainlinkL2PriceOracleAdapter",
                string.concat("PriceOracle adapter for ", assetSymbol, " already wired")
            );
        }
    }

    function _setupChainBalanceOracleAdapters() internal {
        uint256 earningChainId = _configUint(".earningChain.chainId");
        string memory saltSeed = getChainlinkL2ChainBalanceOracleAdapterSaltSeed(earningChainId);
        address predicted = getChainlinkL2ChainBalanceOracleAdapterAddress(earningChainId, _deployer());
        bytes memory initCode = abi.encodePacked(
            type(ChainlinkL2ChainBalanceOracleAdapter).creationCode,
            abi.encode(
                earningChainId,
                _chainlinkBundleAggregatorProxy,
                _configUint(".chainlinkChainBalanceOracleHeartbeat"),
                _sequencerUptimeFeed
            )
        );
        address adapter;
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(predicted, initCode, "ChainlinkL2ChainBalanceOracleAdapter");
            adapter = predicted;
            logSkip("_setupChainBalanceOracleAdapters", "ChainlinkL2ChainBalanceOracleAdapter");
        } else {
            adapter = _deploy_create3({namespacedSaltSeed: saltSeed, deployer: _deployer(), initCode: initCode});
            require(adapter == predicted, "ChainlinkL2ChainBalanceOracleAdapter does not match expected address");
        }
        _logDeployment("ChainlinkL2ChainBalanceOracleAdapter", saltSeed, adapter);
        ChainBalanceOracle chainBalanceOracle = ChainBalanceOracle(getChainBalanceOracleAddress(_deployer()));
        /// @custom:tx-already-executed-check Skip when ChainBalanceOracle is already pointing at this adapter for the
        /// chain.
        if (chainBalanceOracle.getChainBalanceOracleAdapter(earningChainId) != adapter) {
            chainBalanceOracle.setChainBalanceOracleAdapter(earningChainId, adapter);
        } else {
            logSkip("_setupChainBalanceOracleAdapters", "ChainBalanceOracle adapter already wired");
        }
    }

    function _setupDepositPolicy() internal {
        DepositPolicy policy = DepositPolicy(getDepositPolicyAddress(_deployer()));

        IPolicyRegistry policyRegistry = IPolicyRegistry(getPolicyRegistryAddress(_deployer()));
        /// @custom:tx-already-executed-check Skip when registry already points at this policy.
        if (policyRegistry.getPolicy(DEPOSIT_POLICY_ID) != address(policy)) {
            policyRegistry.setPolicy(DEPOSIT_POLICY_ID, address(policy));
        } else {
            logSkip("_setupDepositPolicy", "deposit policy already set in registry");
        }

        _initDepositLimit(policy, _gho(), ".accountingChain.depositPolicy.perAssetLimits.gho");
        _initDepositLimit(policy, _usdc(), ".accountingChain.depositPolicy.perAssetLimits.usdc");
        _initDepositLimit(policy, _usdt(), ".accountingChain.depositPolicy.perAssetLimits.usdt");
        _initGlobalDepositLimit(policy, ".accountingChain.depositPolicy.globalLimit");
    }

    function _initGlobalDepositLimit(DepositPolicy policy, string memory configKey) private {
        uint128 capacity = _configUint128(string.concat(configKey, ".capacity"));
        uint128 refillRate = _configUint128(string.concat(configKey, ".refillRate"));
        RateLimitBucketLib.Bucket memory bucket = policy.getGlobalDepositLimit();
        if (bucket.capacity < capacity) {
            policy.raiseGlobalDepositCapacity(capacity);
        } else {
            /// @custom:tx-already-executed-check Capacity matches target; reject drift above target.
            require(bucket.capacity == capacity, "global deposit capacity mismatch");
            logSkip("_initGlobalDepositLimit", "global deposit capacity");
        }
        if (bucket.refillRate < refillRate) {
            policy.raiseGlobalDepositRefillRate(refillRate);
        } else {
            /// @custom:tx-already-executed-check Refill rate matches target; reject drift above target.
            require(bucket.refillRate == refillRate, "global deposit refill rate mismatch");
            logSkip("_initGlobalDepositLimit", "global deposit refill rate");
        }
    }

    function _initDepositLimit(DepositPolicy policy, address asset, string memory configKey) private {
        uint128 capacity = _configUint128(string.concat(configKey, ".capacity"));
        uint128 refillRate = _configUint128(string.concat(configKey, ".refillRate"));
        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        if (bucket.capacity < capacity) {
            policy.raiseDepositCapacity(asset, capacity);
        } else {
            /// @custom:tx-already-executed-check Capacity matches target; reject drift above target.
            require(bucket.capacity == capacity, "deposit capacity mismatch");
            logSkip("_initDepositLimit", "deposit capacity");
        }
        if (bucket.refillRate < refillRate) {
            policy.raiseDepositRefillRate(asset, refillRate);
        } else {
            /// @custom:tx-already-executed-check Refill rate matches target; reject drift above target.
            require(bucket.refillRate == refillRate, "deposit refill rate mismatch");
            logSkip("_initDepositLimit", "deposit refill rate");
        }
    }
}
