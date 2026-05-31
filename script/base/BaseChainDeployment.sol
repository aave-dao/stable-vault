// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {ICrossChainReceiver} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainReceiver.sol";
import {IWithGuardian} from "aave-delivery-infrastructure/contracts/old-oz/interfaces/IWithGuardian.sol";
import {AccessManager} from "openzeppelin-contracts/contracts/access/manager/AccessManager.sol";

import {ATokenVaultDeployment} from "script/base/ATokenVaultDeployment.sol";
import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {Create3Deployment} from "script/base/Create3Deployment.sol";
import {logSkip} from "script/libraries/DeploymentLogLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";

import {BaseBridgeAdapter} from "src/bridging/BaseBridgeAdapter.sol";
import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {Allocator} from "src/core/Allocator.sol";
import {BaseChainGateway} from "src/core/BaseChainGateway.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {AggregatorV3Interface} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {PolicyRegistry} from "src/periphery/PolicyRegistry.sol";
import {SlippageCoverageVault} from "src/periphery/SlippageCoverageVault.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {FundsBridgingPolicy} from "src/policies/FundsBridgingPolicy.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";

abstract contract BaseChainDeployment is Create3Deployment, AccessManagerBaseSetup, ATokenVaultDeployment {
    using Strings for address;

    address immutable PROXY_ADMIN_OWNER = getAccessManagerAddress(_deployer());
    address immutable ALLOCATOR_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable WITHDRAWAL_EXECUTION_POLICY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable ASSET_REGISTRY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable GATEWAY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable IOU_TOKEN_MANAGER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable PRICE_ORACLE_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;

    address immutable ACCESS_MANAGER_ADMIN = _deployer();

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Chain-specific hooks (provided by subclasses).
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Config key prefix for this chain's section (e.g. ".accountingChain").
    function _chainConfigPrefix() internal pure virtual returns (string memory);

    /// @dev Config key prefix for the counterparty chain.
    function _remoteChainConfigPrefix() internal pure virtual returns (string memory);

    /// @dev Human-readable chain label used in revert reasons (e.g. "accounting-chain").
    function _chainName() internal pure virtual returns (string memory);

    function _withdrawalExecutionPolicyId() internal pure virtual returns (bytes32);

    function _bridgePolicyId() internal pure virtual returns (bytes32);

    /// @dev Target contract that the WithdrawalExecutionPolicy guards (StableVault on accounting chain, Gateway on
    /// earning chain).
    function _withdrawalExecutionPolicyTarget() internal view virtual returns (address);

    /// @dev StableVault address for the IouTokenManager (zero on earning chain).
    function _iouTokenManagerVault() internal view virtual returns (address);

    function _isAccountingChain() internal pure virtual returns (bool);

    function _allocatorDepositor() internal view virtual returns (address);

    function _allocatorWithdrawer() internal view virtual returns (address);

    function _deployContracts() internal virtual;

    function _setupContracts() internal virtual;

    /// @dev Optional chain-specific validation extensions.
    function _validateChainSpecificDeploymentParameters() internal view virtual {}

    function _validateChainSpecificExternalAddresses() internal view virtual {}

    function _assertChainSpecificRequiredPoliciesSet() internal view virtual {}

    /// @dev Underlyings that this chain's `_setupAllocator` deploys a fresh aTokenVault for. Drives both the
    /// pre-deploy funding check (1 unit of each underlying must be on the deployer) and the actual aTokenVault
    /// deployments inside `_setupAllocator`.
    function _aTokenVaultUnderlyings() internal view virtual returns (address[] memory);

    /// @dev Chain-specific extra Allocator strategies to register on top of the aTokenVaults deployed for
    /// `_aTokenVaultUnderlyings()`. Earning chain uses this to register existing ERC4626 strategies (e.g. sGho).
    function _registerExtraAllocatorStrategies(IAllocator allocator) internal virtual {}

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Asset accessors.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _gho() internal view returns (address) {
        return _configAddress(string.concat(_chainConfigPrefix(), ".assets.gho"));
    }

    function _usdc() internal view returns (address) {
        return _configAddress(string.concat(_chainConfigPrefix(), ".assets.usdc"));
    }

    function _usdt() internal view returns (address) {
        return _configAddress(string.concat(_chainConfigPrefix(), ".assets.usdt"));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Entry point.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    /// @dev Tracks whether `vm.startBroadcast` is active so reference-deploy helpers can pause/resume the broadcast
    /// without leaking auxiliary contracts to chain. Set on entry to `run()`, cleared on exit. Not used by tests, which
    /// drive `_deployContracts` under `vm.startPrank` instead of `vm.startBroadcast`.
    bool private _isBroadcasting;

    function run() public {
        _validateProfileAddresses();
        _validateDeploymentParameters();
        _validateRedemptionLimitConfig(string.concat(_chainConfigPrefix(), ".withdrawalExecutionPolicy"));
        _validateExternalAddresses();
        _validateDeployerFunding();
        _isBroadcasting = true;
        vm.startBroadcast(_deployer());
        _deployContracts();
        _setupContracts();
        vm.stopBroadcast();
        _isBroadcasting = false;
    }

    function _validateDeploymentParameters() internal view virtual {
        _validateCommonDeploymentParameters();
        require(
            block.chainid == _configUint(string.concat(_chainConfigPrefix(), ".chainId")),
            string.concat("must deploy on ", _chainName())
        );
        _validateChainSpecificDeploymentParameters();
    }

    function _validateExternalAddresses() internal view virtual {
        // Validate ERC20 token addresses
        IERC20(_gho()).balanceOf(_deployer());
        IERC20(_usdc()).balanceOf(_deployer());
        IERC20(_usdt()).balanceOf(_deployer());

        // Validate Chainlink price feed addresses
        address ghoUsdFeed = _configAddress(string.concat(_chainConfigPrefix(), ".chainlinkFeeds.ghoUsd"));
        require(ghoUsdFeed != address(0), "Chainlink GHO/USD data feed not set");
        AggregatorV3Interface(ghoUsdFeed).latestRoundData();

        address usdcUsdFeed = _configAddress(string.concat(_chainConfigPrefix(), ".chainlinkFeeds.usdcUsd"));
        require(usdcUsdFeed != address(0), "Chainlink USDC/USD data feed not set");
        AggregatorV3Interface(usdcUsdFeed).latestRoundData();

        address usdtUsdFeed = _configAddress(string.concat(_chainConfigPrefix(), ".chainlinkFeeds.usdtUsd"));
        require(usdtUsdFeed != address(0), "Chainlink USDT/USD data feed not set");
        AggregatorV3Interface(usdtUsdFeed).latestRoundData();

        // Validate CCIP router supports the counterparty chain
        require(
            IRouterClient(_configAddress(string.concat(_chainConfigPrefix(), ".ccipRouterAddress")))
                .isChainSupported(_configUint64(string.concat(_remoteChainConfigPrefix(), ".ccipSelector"))),
            "CCIP Router does not support counterparty chain"
        );

        // Validate Aave V3 pool addresses provider
        require(
            _configAddress(string.concat(_chainConfigPrefix(), ".aaveV3PoolAddressesProvider")) != address(0),
            "Aave V3 pool addresses provider not set"
        );

        // Validate withdrawal policy signer
        require(_configAddress(".withdrawalExecutionPolicy.signer") != address(0), "Withdrawal policy signer not set");

        if (_shouldRegisterAdiOnGateway()) {
            _validateAdiConfiguration();
        }

        _validateChainSpecificExternalAddresses();
    }

    function _validateAdiConfiguration() internal view virtual {
        address adiCrossChainController = _adiCrossChainController();
        require(adiCrossChainController != address(0), "Adi CCC address not set");
        require(adiCrossChainController.code.length != 0, "Adi CCC has no code");
        require(
            Ownable(adiCrossChainController).owner() == getAccessManagerAddress(_deployer()),
            "Adi CCC owner is not AccessManager"
        );
        require(
            IWithGuardian(adiCrossChainController).guardian() == getAdiAdapterAddress(_deployer()),
            "Adi CCC guardian is not AdiAdapter"
        );

        uint256 remoteChainId = _configUint(string.concat(_remoteChainConfigPrefix(), ".chainId"));
        ICrossChainForwarder forwarder = ICrossChainForwarder(adiCrossChainController);
        forwarder.getCurrentEnvelopeNonce();
        forwarder.getCurrentTransactionNonce();
        require(
            forwarder.getForwarderBridgeAdaptersByChain(remoteChainId).length > 0, "Adi CCC forwarder adapters not set"
        );

        ICrossChainReceiver receiver = ICrossChainReceiver(adiCrossChainController);
        require(
            receiver.getReceiverBridgeAdaptersByChain(remoteChainId).length > 0, "Adi CCC receiver adapters not set"
        );
        ICrossChainReceiver.ReceiverConfiguration memory receiverConfiguration =
            receiver.getConfigurationByChain(remoteChainId);
        require(receiverConfiguration.requiredConfirmation > 0, "Adi CCC receiver confirmations not set");
    }

    /// @dev Asserts that the deployer holds enough native + ERC20 balance to complete the deploy. Runs before
    /// `vm.startBroadcast` so a missing pre-setup fails fast with a clear message instead of mid-broadcast.
    function _validateDeployerFunding() internal view virtual {
        address deployer = _deployer();
        require(deployer.balance > 0, "deployer has zero native balance");

        address[] memory underlyings = _aTokenVaultUnderlyings();
        for (uint256 i = 0; i < underlyings.length; i++) {
            address underlying = underlyings[i];
            // Skip already-deployed vaults: a prior run already pulled the 1-unit initial-lock deposit, so the
            // deployer's balance can legitimately be below the threshold on resume.
            if (_predictedATokenVaultAddress(underlying, deployer).code.length != 0) {
                continue;
            }
            uint256 required = 10 ** IERC20Metadata(underlying).decimals();
            require(
                IERC20(underlying).balanceOf(deployer) >= required,
                string.concat(
                    "deployer underfunded for aTokenVault initial-lock deposit: ",
                    IERC20Metadata(underlying).symbol(),
                    " at ",
                    Strings.toHexString(underlying)
                )
            );
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // AccessManagerBaseSetup overrides.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _accessManager() internal view virtual override returns (address) {
        return getAccessManagerAddress(_deployer());
    }

    function _shouldRegisterAdiOnGateway() internal view virtual override returns (bool) {
        return _configBool(string.concat(_chainConfigPrefix(), ".adi.registerOnGateway"));
    }

    function _adiCrossChainController() internal view virtual override returns (address) {
        return _configAddress(string.concat(_chainConfigPrefix(), ".adi.crossChainController"));
    }

    /// @dev File the deployment writes its addresses to (and reads back to resume). Virtual so fork tests can redirect
    /// it to a throwaway path and avoid mutating the tracked deployment JSON.
    function _deploymentOutputPath() internal view virtual returns (string memory) {
        return _configString(string.concat(_chainConfigPrefix(), ".deploymentOutputPath"));
    }

    function _deployedATokenVaultAddresses() internal view virtual override returns (address[] memory) {
        return _readATokenVaultAddresses(_deploymentOutputPath());
    }

    function _aTokenVaultProxyDeployerSaltSeed(address underlying) internal pure override returns (string memory) {
        return getATokenVaultProxyDeployerSaltSeed(underlying);
    }

    function _aTokenVaultMerklRewardClaimerImplSaltSeed(address underlying)
        internal
        pure
        override
        returns (string memory)
    {
        return getATokenVaultMerklRewardClaimerImplSaltSeed(underlying);
    }

    function _assertATokenVaultMerklRewardClaimerImplBytecode(address actual, bytes memory implInitCode)
        internal
        override
    {
        _assertDeployedMatchesReference(actual, implInitCode, "ATokenVaultMerklRewardClaimer::Implementation");
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal virtual override {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, _deploymentOutputPath(), string.concat(".", name));
    }

    function _logATokenVaultDeployments() internal override {
        vm.writeJson(_buildATokenVaultsJson(), _deploymentOutputPath(), ".aTokenVaults");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Shared setup helpers.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupBridgeAdapters() internal {
        // NOTE: This assumes adapters of same type are having the same address on all chains.
        address localCcipAdapter = getCcipAdapterAddress(_deployer());
        address remoteCcipAdapter = localCcipAdapter;

        IChainGateway gateway = IChainGateway(getGatewayAddress(_deployer()));

        uint256 remoteChainId = _configUint(string.concat(_remoteChainConfigPrefix(), ".chainId"));
        uint64 remoteCcipSelector = _configUint64(string.concat(_remoteChainConfigPrefix(), ".ccipSelector"));

        _addFundsBridgeAdapterIdempotent(gateway, _gho(), remoteChainId, localCcipAdapter);
        _addFundsBridgeAdapterIdempotent(gateway, _usdc(), remoteChainId, localCcipAdapter);
        _addFundsBridgeAdapterIdempotent(gateway, _usdt(), remoteChainId, localCcipAdapter);

        /// @custom:tx-already-executed-check CCIP chain selector already set.
        if (ICcipBridgeAdapter(localCcipAdapter).getChainSelector(remoteChainId) != remoteCcipSelector) {
            ICcipBridgeAdapter(localCcipAdapter).setChainSelector(remoteChainId, remoteCcipSelector);
        } else {
            logSkip("_setupBridgeAdapters", "CCIP chain selector");
        }
        _setDestinationChainAdapterIdempotent(localCcipAdapter, remoteChainId, remoteCcipAdapter);

        if (_shouldRegisterAdiOnGateway()) {
            // NOTE: Assumes the aDI adapter has the same address on both chains (CREATE3 + same deployer/salt).
            address localAdiAdapter = getAdiAdapterAddress(_deployer());
            address remoteAdiAdapter = localAdiAdapter;
            _setDestinationChainAdapterIdempotent(localAdiAdapter, remoteChainId, remoteAdiAdapter);
            _addDataOnlyBridgeAdapterIdempotent(gateway, remoteChainId, localAdiAdapter);
        }
    }

    function _addFundsBridgeAdapterIdempotent(
        IChainGateway gateway,
        address asset,
        uint256 chainId,
        address bridgeAdapter
    ) private {
        /// @custom:tx-already-executed-check Skip when the (asset, chainId, bridgeAdapter) triple is already
        /// whitelisted on the gateway. This is the primary resume signal - a fresh attempt would revert with
        /// `AddressAlreadyWhitelisted`, and crucially forge would still capture that reverting call into the
        /// post-script broadcast simulation, failing the run.
        if (BaseChainGateway(address(gateway)).isFundsBridgeAdapterSupported(asset, chainId, bridgeAdapter)) {
            logSkip("_addFundsBridgeAdapterIdempotent", "funds bridge adapter registered");
            return;
        }
        /// @custom:tx-already-executed-check Skip when the deployer can no longer call `addFundsBridgeAdapter` -
        /// `_setupAccessManager` revokes the deployer's ADMIN_ROLE as its last step, so losing call access means a
        /// prior run completed everything up to and including bridge-adapter setup. This branch is reachable only if
        /// the registration check above somehow missed (e.g. on a future schema change), kept as a safety net.
        if (!_deployerCanCall(address(gateway), IChainGateway.addFundsBridgeAdapter.selector)) {
            logSkip("_addFundsBridgeAdapterIdempotent", "deployer lacks call access - prior run completed");
            return;
        }
        gateway.addFundsBridgeAdapter(asset, chainId, bridgeAdapter);
    }

    function _addDataOnlyBridgeAdapterIdempotent(IChainGateway gateway, uint256 chainId, address bridgeAdapter)
        private
    {
        IChainGateway.DataOnlyBridgeAdapterMode mode =
            BaseChainGateway(address(gateway)).getDataOnlyBridgeAdapterMode(chainId, bridgeAdapter);
        /// @custom:tx-already-executed-check Data-only adapter already registered.
        if (mode == IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE) {
            logSkip("_addDataOnlyBridgeAdapterIdempotent", "data-only bridge adapter registered");
            return;
        }
        require(
            mode == IChainGateway.DataOnlyBridgeAdapterMode.NOT_SUPPORTED,
            "data-only bridge adapter mode does not match expected value"
        );
        /// @custom:tx-already-executed-check See `_addFundsBridgeAdapterIdempotent` for the same canCall safety-net.
        if (!_deployerCanCall(address(gateway), IChainGateway.addDataOnlyBridgeAdapter.selector)) {
            logSkip("_addDataOnlyBridgeAdapterIdempotent", "deployer lacks call access - prior run completed");
            return;
        }
        gateway.addDataOnlyBridgeAdapter(chainId, bridgeAdapter);
    }

    function _setDestinationChainAdapterIdempotent(address adapter, uint256 chainId, address destAdapter) private {
        /// @custom:tx-already-executed-check Skip when the destination adapter is already set to  `destAdapter`
        /// for `chainId`.
        address current = BaseBridgeAdapter(adapter).getDestinationChainAdapter(chainId);
        if (current == destAdapter) {
            logSkip("_setDestinationChainAdapterIdempotent", "destination chain adapter configured");
            return;
        }
        require(
            current == address(0),
            "setDestinationChainAdapter: existing destination adapter does not match expected value"
        );
        /// @custom:tx-already-executed-check See `_addFundsBridgeAdapterIdempotent` for the same canCall safety-net.
        if (!_deployerCanCall(adapter, IBridgeAdapter.setDestinationChainAdapter.selector)) {
            logSkip("_setDestinationChainAdapterIdempotent", "deployer lacks call access - prior run completed");
            return;
        }
        IBridgeAdapter(adapter).setDestinationChainAdapter(chainId, destAdapter);
    }

    /// @dev Returns whether the deployer can currently invoke `selector` on `target` via the configured AccessManager.
    /// Used to short-circuit access-managed idempotent helpers on resume after the deployer's ADMIN_ROLE has been
    /// revoked - calling regardless would revert and, more importantly, be captured by forge for broadcast and fail
    /// the broadcast simulation even if the script's try/catch suppressed the in-memory revert.
    function _deployerCanCall(address target, bytes4 selector) private view returns (bool) {
        (bool ok,) = IAccessManager(_accessManager()).canCall(_deployer(), target, selector);
        return ok;
    }

    function _setupAssetRegistry() internal {
        IAssetRegistry assetRegistry = IAssetRegistry(getAssetRegistryAddress(_deployer()));
        IAssetRegistry.AssetConfig memory unrestrictedAssetConfig = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        _setAssetConfigIdempotent(assetRegistry, _gho(), unrestrictedAssetConfig);
        _setAssetConfigIdempotent(assetRegistry, _usdc(), unrestrictedAssetConfig);
        _setAssetConfigIdempotent(assetRegistry, _usdt(), unrestrictedAssetConfig);
    }

    function _setAssetConfigIdempotent(
        IAssetRegistry assetRegistry,
        address asset,
        IAssetRegistry.AssetConfig memory config
    ) private {
        /// @custom:tx-already-executed-check Asset already registered.
        if (!assetRegistry.isAssetRegistered(asset)) {
            assetRegistry.setAssetConfig(asset, config);
        } else {
            logSkip("_setAssetConfigIdempotent", "asset registered");
        }
    }

    function _addStrategyIdempotent(IAllocator allocator, address asset, address strategy) internal {
        /// @custom:tx-already-executed-check Strategy already registered.
        if (!allocator.isStrategySupportedForAsset(asset, strategy)) {
            allocator.addStrategy(asset, strategy);
        } else {
            logSkip("_addStrategyIdempotent", "strategy");
        }
    }

    function _setupAllocator() internal {
        IAllocator allocator = IAllocator(getAllocatorAddress(_deployer()));
        _registerExtraAllocatorStrategies(allocator);
        address poolAddressProvider =
            _configAddress(string.concat(_chainConfigPrefix(), ".aaveV3PoolAddressesProvider"));
        address accessManager = getAccessManagerAddress(_deployer());
        address[] memory underlyings = _aTokenVaultUnderlyings();
        for (uint256 i = 0; i < underlyings.length; i++) {
            address strategy = _deployATokenVault(underlyings[i], poolAddressProvider, accessManager, _deployer());
            _addStrategyIdempotent(allocator, underlyings[i], strategy);
        }
    }

    function _setupWithdrawalExecutionPolicy() internal {
        WithdrawalExecutionPolicy withdrawalExecutionPolicy =
            WithdrawalExecutionPolicy(getWithdrawalExecutionPolicyAddress(_deployer()));

        uint16 defaultFeeBps = _configUint16(".withdrawalExecutionPolicy.defaultFeeBps");
        /// @custom:tx-already-executed-check Default fee already at target.
        if (withdrawalExecutionPolicy.getDefaultFeeBps() != defaultFeeBps) {
            withdrawalExecutionPolicy.setDefaultFeeBps(defaultFeeBps);
        } else {
            logSkip("_setupWithdrawalExecutionPolicy", "default fee bps");
        }

        address signer = _configAddress(".withdrawalExecutionPolicy.signer");
        /// @custom:tx-already-executed-check Signer already registered.
        if (!withdrawalExecutionPolicy.isSigner(signer)) {
            withdrawalExecutionPolicy.addSigner(signer);
        } else {
            logSkip("_setupWithdrawalExecutionPolicy", "signer");
        }

        _initRedemptionLimit(
            withdrawalExecutionPolicy, string.concat(_chainConfigPrefix(), ".withdrawalExecutionPolicy.redemptionLimit")
        );

        IPolicyRegistry policyRegistry = IPolicyRegistry(getPolicyRegistryAddress(_deployer()));
        /// @custom:tx-already-executed-check Registry already points at this policy.
        if (policyRegistry.getPolicy(_withdrawalExecutionPolicyId()) != address(withdrawalExecutionPolicy)) {
            policyRegistry.setPolicy(_withdrawalExecutionPolicyId(), address(withdrawalExecutionPolicy));
        } else {
            logSkip("_setupWithdrawalExecutionPolicy", "policy registry entry");
        }
    }

    function _initRedemptionLimit(WithdrawalExecutionPolicy policy, string memory configKey) private {
        uint128 capacityRay = _configUint128(string.concat(configKey, ".capacityRay"));
        uint128 refillRateRay = _configUint128(string.concat(configKey, ".refillRateRay"));
        RateLimitBucketLib.Bucket memory bucket = policy.getRedemptionBucket();
        if (bucket.capacity < capacityRay) {
            policy.raiseRedemptionCapacity(capacityRay);
        } else {
            /// @custom:tx-already-executed-check Capacity matches target; reject drift above target.
            require(bucket.capacity == capacityRay, "redemption capacity mismatch");
            logSkip("_initRedemptionLimit", "redemption capacity");
        }
        if (bucket.refillRate < refillRateRay) {
            policy.raiseRedemptionRefillRate(refillRateRay);
        } else {
            /// @custom:tx-already-executed-check Refill rate matches target; reject drift above target.
            require(bucket.refillRate == refillRateRay, "redemption refill rate mismatch");
            logSkip("_initRedemptionLimit", "redemption refill rate");
        }
    }

    function _setupFundsBridgingPolicy() internal {
        FundsBridgingPolicy policy = FundsBridgingPolicy(getFundsBridgingPolicyAddress(_deployer()));

        IPolicyRegistry policyRegistry = IPolicyRegistry(getPolicyRegistryAddress(_deployer()));
        /// @custom:tx-already-executed-check Registry already points at this policy.
        if (policyRegistry.getPolicy(_bridgePolicyId()) != address(policy)) {
            policyRegistry.setPolicy(_bridgePolicyId(), address(policy));
        } else {
            logSkip("_setupFundsBridgingPolicy", "policy registry entry");
        }

        uint256 destChainId = _configUint(string.concat(_remoteChainConfigPrefix(), ".chainId"));
        address bridgeAdapter = getCcipAdapterAddress(_deployer());
        string memory limitsPrefix = string.concat(_chainConfigPrefix(), ".fundsBridgingPolicy.perAssetLimits");

        _initBridgingLimit(policy, _gho(), destChainId, bridgeAdapter, string.concat(limitsPrefix, ".gho"));
        _initBridgingLimit(policy, _usdc(), destChainId, bridgeAdapter, string.concat(limitsPrefix, ".usdc"));
        _initBridgingLimit(policy, _usdt(), destChainId, bridgeAdapter, string.concat(limitsPrefix, ".usdt"));
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
        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, destChainId, bridgeAdapter);
        if (bucket.capacity < capacity) {
            policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, capacity);
        } else {
            /// @custom:tx-already-executed-check Capacity matches target; reject drift above target.
            require(bucket.capacity == capacity, "bridging capacity mismatch");
            logSkip("_initBridgingLimit", "bridging capacity");
        }
        if (bucket.refillRate < refillRate) {
            policy.raiseBridgingRefillRate(asset, destChainId, bridgeAdapter, refillRate);
        } else {
            /// @custom:tx-already-executed-check Refill rate matches target; reject drift above target.
            require(bucket.refillRate == refillRate, "bridging refill rate mismatch");
            logSkip("_initBridgingLimit", "bridging refill rate");
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
            /// @custom:tx-already-executed-check Pull cap already configured; assert it matches target.
            require(currentPullCap == pullCapPerTx, "SCV pullCapPerTx mismatch");
            logSkip("_ensureNonZeroSlippageCoverageVaultAssetCaps", "SCV pull cap per tx");
        }

        SlippageCoverageVault.Window memory window = vault.getWindow(asset);
        if (window.cap == 0) {
            vault.raiseWindowCap(asset, windowCap);
        } else {
            /// @custom:tx-already-executed-check Window cap already configured; assert it matches target.
            require(window.cap == windowCap, "SCV windowCap mismatch");
            logSkip("_ensureNonZeroSlippageCoverageVaultAssetCaps", "SCV window cap");
        }

        window = vault.getWindow(asset);
        if (window.windowSeconds == 0) {
            vault.raiseWindowSeconds(asset, windowSeconds);
        } else {
            /// @custom:tx-already-executed-check Window seconds already configured; assert it matches target.
            require(window.windowSeconds == windowSeconds, "SCV windowSeconds mismatch");
            logSkip("_ensureNonZeroSlippageCoverageVaultAssetCaps", "SCV window seconds");
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

    function _assertRequiredPoliciesSet() internal view {
        IPolicyRegistry registry = IPolicyRegistry(getPolicyRegistryAddress(_deployer()));
        address policyAddress = registry.getPolicy(_withdrawalExecutionPolicyId());
        require(policyAddress != address(0), string.concat("missing ", _chainName(), " withdrawal-execution policy"));
        require(
            registry.getPolicy(_bridgePolicyId()) != address(0),
            string.concat("missing ", _chainName(), " bridge policy")
        );

        WithdrawalExecutionPolicy policy = WithdrawalExecutionPolicy(policyAddress);
        RateLimitBucketLib.Bucket memory bucket = policy.getRedemptionBucket();
        // Strict greater than: seeding at floor leaves the bucket pinned with no headroom for `lower*` during
        // incident response. Force operator headroom by construction.
        require(
            bucket.capacity > policy.getMinRedemptionCapacity(),
            string.concat(_chainName(), " redemption capacity must exceed floor")
        );
        require(
            bucket.refillRate > policy.getMinRedemptionRefillRate(),
            string.concat(_chainName(), " redemption refill rate must exceed floor")
        );

        _assertChainSpecificRequiredPoliciesSet();
    }

    function _assertDeployedTransparentProxy(
        address proxy,
        bytes memory implCreationCode,
        address expectedProxyAdminOwner,
        string memory name
    ) internal {
        address impl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(
            impl != address(0),
            string.concat(name, "::Proxy at ", Strings.toHexString(proxy), ": ERC-1967 implementation slot is zero")
        );
        address admin = address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT))));
        require(
            admin != address(0),
            string.concat(name, "::Proxy at ", Strings.toHexString(proxy), ": ERC-1967 admin slot is zero")
        );
        require(
            ProxyAdmin(admin).owner() == expectedProxyAdminOwner,
            string.concat(
                name,
                "::ProxyAdmin at ",
                Strings.toHexString(admin),
                ": owner does not match expected upgrade-authority address"
            )
        );
        _assertDeployedMatchesReference(impl, implCreationCode, string.concat(name, "::Implementation"));
    }

    /// @dev Deploys a reference copy of the contract described by `creationCode` (creation bytecode + ABI-encoded
    /// constructor args) and asserts the on-chain runtime code at `actual` matches the reference byte-for-byte. The
    /// reference is created via inline-assembly `CREATE`, which bypasses Foundry's broadcast hook even when called from
    /// within a `vm.startBroadcast` block; we pause/resume broadcast anyway so the reference is never published to
    /// chain. Catches the case where `actual` has code that resembles "ours" but was produced from different
    /// constructor args (e.g. a stale prior deploy, or a same-salt collision with a different deployer flow).
    function _assertDeployedMatchesReference(address actual, bytes memory creationCode, string memory name) internal {
        if (_isBroadcasting) {
            vm.stopBroadcast();
        }
        address ref;
        assembly {
            ref := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        if (_isBroadcasting) {
            vm.startBroadcast(_deployer());
        }
        require(
            ref != address(0), string.concat(name, " at ", Strings.toHexString(actual), ": reference deploy failed")
        );
        require(
            keccak256(actual.code) == keccak256(ref.code),
            string.concat(name, " at ", Strings.toHexString(actual), ": deployed bytecode mismatch")
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Shared deploys.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _deployTransferHelper() internal returns (address) {
        address predicted = getTransferHelperAddress(_deployer());
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedRuntimeCode(predicted, keccak256(type(TransferHelper).runtimeCode), "TransferHelper");
            logSkip("_deployTransferHelper", "TransferHelper");
            _logDeployment("TransferHelper", TRANSFER_HELPER_SALT_SEED, predicted);
            return predicted;
        }
        address transferHelper = _deploy_create3({
            namespacedSaltSeed: TRANSFER_HELPER_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(type(TransferHelper).creationCode)
        });
        require(transferHelper == predicted, "TransferHelper does not match expected address");
        _logDeployment("TransferHelper", TRANSFER_HELPER_SALT_SEED, transferHelper);
        return transferHelper;
    }

    function _deployAccessManager() internal returns (address) {
        address predicted = getAccessManagerAddress(_deployer());
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedRuntimeCode(predicted, keccak256(type(AccessManager).runtimeCode), "AccessManager");
            logSkip("_deployAccessManager", "AccessManager");
            _logDeployment("AccessManager", ACCESS_MANAGER_SALT_SEED, predicted);
            return predicted;
        }
        address accessManager = _deploy_create3({
            namespacedSaltSeed: ACCESS_MANAGER_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(type(AccessManager).creationCode, abi.encode(ACCESS_MANAGER_ADMIN))
        });
        require(accessManager == predicted, "AccessManager does not match expected address");
        _logDeployment("AccessManager", ACCESS_MANAGER_SALT_SEED, accessManager);
        return accessManager;
    }

    function _deployAssetRegistry() internal returns (address) {
        address predicted = getAssetRegistryAddress(_deployer());
        bytes memory implCreationCode = type(AssetRegistry).creationCode;
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(
                predicted, implCreationCode, ASSET_REGISTRY_PROXY_ADMIN_OWNER, "AssetRegistry"
            );
            logSkip("_deployAssetRegistry", "AssetRegistry");
            _logDeployment("AssetRegistry", ASSET_REGISTRY_SALT_SEED, predicted);
            return predicted;
        }
        address implementation = address(new AssetRegistry());
        _logDeployment("AssetRegistry::Implementation", "", implementation);
        address assetRegistry = _deployTransparentProxy_create3({
            namespacedSaltSeed: ASSET_REGISTRY_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: ASSET_REGISTRY_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(AssetRegistry.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(assetRegistry == predicted, "AssetRegistry does not match expected address");
        _logDeployment("AssetRegistry", ASSET_REGISTRY_SALT_SEED, assetRegistry);
        return assetRegistry;
    }

    function _deployWithdrawalExecutionPolicy() internal returns (address) {
        address predicted = getWithdrawalExecutionPolicyAddress(_deployer());
        uint128 minRedemptionCapacityRay =
            _configUint128(string.concat(_chainConfigPrefix(), ".withdrawalExecutionPolicy.minRedemptionCapacityRay"));
        uint128 minRedemptionRefillRateRay = _configUint128(
            string.concat(_chainConfigPrefix(), ".withdrawalExecutionPolicy.minRedemptionRefillRateRay")
        );
        bytes memory implCreationCode = abi.encodePacked(
            type(WithdrawalExecutionPolicy).creationCode,
            abi.encode(_withdrawalExecutionPolicyTarget(), minRedemptionCapacityRay, minRedemptionRefillRateRay)
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(
                predicted, implCreationCode, WITHDRAWAL_EXECUTION_POLICY_PROXY_ADMIN_OWNER, "WithdrawalExecutionPolicy"
            );
            logSkip("_deployWithdrawalExecutionPolicy", "WithdrawalExecutionPolicy");
            _logDeployment("WithdrawalExecutionPolicy", WITHDRAWAL_EXECUTION_POLICY_SALT_SEED, predicted);
            return predicted;
        }
        address implementation = address(
            new WithdrawalExecutionPolicy(
                _withdrawalExecutionPolicyTarget(), minRedemptionCapacityRay, minRedemptionRefillRateRay
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
        require(withdrawalExecutionPolicy == predicted, "WithdrawalExecutionPolicy does not match expected address");
        _logDeployment("WithdrawalExecutionPolicy", WITHDRAWAL_EXECUTION_POLICY_SALT_SEED, withdrawalExecutionPolicy);
        return withdrawalExecutionPolicy;
    }

    function _deployIouToken() internal returns (address) {
        address predicted = getIouTokenAddress(_deployer());
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedRuntimeCode(predicted, keccak256(type(IouToken).runtimeCode), "IouToken");
            logSkip("_deployIouToken", "IouToken");
            _logDeployment("IouToken", IOU_TOKEN_SALT_SEED, predicted);
            return predicted;
        }
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
        require(iouToken == predicted, "IouToken does not match expected address");
        _logDeployment("IouToken", IOU_TOKEN_SALT_SEED, iouToken);
        return iouToken;
    }

    function _deployIouTokenManager() internal returns (address) {
        address predicted = getIouTokenManagerAddress(_deployer());
        bytes memory implCreationCode = abi.encodePacked(
            type(IouTokenManager).creationCode,
            abi.encode(
                getIouTokenAddress(_deployer()),
                getGatewayAddress(_deployer()),
                _iouTokenManagerVault(),
                _isAccountingChain()
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(
                predicted, implCreationCode, IOU_TOKEN_MANAGER_PROXY_ADMIN_OWNER, "IouTokenManager"
            );
            logSkip("_deployIouTokenManager", "IouTokenManager");
            _logDeployment("IouTokenManager", IOU_TOKEN_MANAGER_SALT_SEED, predicted);
            return predicted;
        }
        address implementation = address(
            new IouTokenManager({
                iouToken: getIouTokenAddress(_deployer()),
                chainGateway: getGatewayAddress(_deployer()),
                vault: _iouTokenManagerVault(),
                isAccountingChain: _isAccountingChain()
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
        require(iouTokenManager == predicted, "IouTokenManager does not match expected address");
        _logDeployment("IouTokenManager", IOU_TOKEN_MANAGER_SALT_SEED, iouTokenManager);
        return iouTokenManager;
    }

    function _deployAllocator() internal returns (address) {
        address predicted = getAllocatorAddress(_deployer());
        bytes memory implCreationCode = abi.encodePacked(
            type(Allocator).creationCode,
            abi.encode(
                getAssetRegistryAddress(_deployer()),
                _allocatorDepositor(),
                _allocatorWithdrawer(),
                getPriceOracleAddress(_deployer()),
                getTransferHelperAddress(_deployer()),
                _configUint8(".maxStrategiesPerAsset"),
                getPolicyRegistryAddress(_deployer())
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(predicted, implCreationCode, ALLOCATOR_PROXY_ADMIN_OWNER, "Allocator");
            logSkip("_deployAllocator", "Allocator");
            _logDeployment("Allocator", ALLOCATOR_SALT_SEED, predicted);
            return predicted;
        }
        address implementation = address(
            new Allocator({
                assetRegistry: getAssetRegistryAddress(_deployer()),
                depositor: _allocatorDepositor(),
                withdrawer: _allocatorWithdrawer(),
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
        require(allocator == predicted, "Allocator does not match expected address");
        _logDeployment("Allocator", ALLOCATOR_SALT_SEED, allocator);
        return allocator;
    }

    function _deploySlippageCoverageVault() internal returns (address) {
        address predicted = getSlippageCoverageVaultAddress(_deployer());
        bytes memory initCode = abi.encodePacked(
            type(SlippageCoverageVault).creationCode,
            abi.encode(
                getSwapperAddress(_deployer()),
                getAccessManagerAddress(_deployer()),
                _configUint16(".slippageCoverageVault.maxSlippageBps"),
                _configUint16(".slippageCoverageVault.overrideMaxSlippageBps"),
                _configBool(".slippageCoverageVault.initialOverrideMode")
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(predicted, initCode, "SlippageCoverageVault");
            logSkip("_deploySlippageCoverageVault", "SlippageCoverageVault");
            _logDeployment("SlippageCoverageVault", SLIPPAGE_COVERAGE_VAULT_SALT_SEED, predicted);
            return predicted;
        }
        address slippageCoverageVault = _deploy_create3({
            namespacedSaltSeed: SLIPPAGE_COVERAGE_VAULT_SALT_SEED, deployer: _deployer(), initCode: initCode
        });
        require(slippageCoverageVault == predicted, "SlippageCoverageVault does not match expected address");
        _logDeployment("SlippageCoverageVault", SLIPPAGE_COVERAGE_VAULT_SALT_SEED, slippageCoverageVault);
        return slippageCoverageVault;
    }

    function _deploySwapper() internal returns (address) {
        address predicted = getSwapperAddress(_deployer());
        bytes memory initCode = abi.encodePacked(
            type(Swapper).creationCode,
            abi.encode(getAllocatorAddress(_deployer()), getSlippageCoverageVaultAddress(_deployer()))
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(predicted, initCode, "Swapper");
            logSkip("_deploySwapper", "Swapper");
            _logDeployment("Swapper", SWAPPER_SALT_SEED, predicted);
            return predicted;
        }
        address swapper =
            _deploy_create3({namespacedSaltSeed: SWAPPER_SALT_SEED, deployer: _deployer(), initCode: initCode});
        require(swapper == predicted, "Swapper does not match expected address");
        _logDeployment("Swapper", SWAPPER_SALT_SEED, swapper);
        return swapper;
    }

    function _deployCcipAdapter() internal returns (address) {
        address predicted = getCcipAdapterAddress(_deployer());
        bytes memory initCode = abi.encodePacked(
            type(CcipAdapter).creationCode,
            abi.encode(
                getAccessManagerAddress(_deployer()),
                getGatewayAddress(_deployer()),
                _configAddress(string.concat(_chainConfigPrefix(), ".ccipRouterAddress")),
                getTransferHelperAddress(_deployer()),
                getAssetRegistryAddress(_deployer())
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(predicted, initCode, "CcipAdapter");
            logSkip("_deployCcipAdapter", "CcipAdapter");
            _logDeployment("CcipAdapter", CCIP_ADAPTER_SALT_SEED, predicted);
            return predicted;
        }
        address ccipAdapter =
            _deploy_create3({namespacedSaltSeed: CCIP_ADAPTER_SALT_SEED, deployer: _deployer(), initCode: initCode});
        require(ccipAdapter == predicted, "CcipAdapter does not match expected address");
        _logDeployment("CcipAdapter", CCIP_ADAPTER_SALT_SEED, ccipAdapter);
        return ccipAdapter;
    }

    function _deployAdiAdapter() internal returns (address) {
        if (_shouldRegisterAdiOnGateway() == false) {
            return address(0);
        }
        address predicted = getAdiAdapterAddress(_deployer());
        bytes memory initCode = abi.encodePacked(
            type(AdiAdapter).creationCode,
            abi.encode(
                getAccessManagerAddress(_deployer()),
                getGatewayAddress(_deployer()),
                _adiCrossChainController(),
                getTransferHelperAddress(_deployer())
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(predicted, initCode, "AdiAdapter");
            logSkip("_deployAdiAdapter", "AdiAdapter");
            _logDeployment("AdiAdapter", ADI_ADAPTER_SALT_SEED, predicted);
            return predicted;
        }
        address adiAdapter =
            _deploy_create3({namespacedSaltSeed: ADI_ADAPTER_SALT_SEED, deployer: _deployer(), initCode: initCode});
        require(adiAdapter == predicted, "AdiAdapter does not match expected address");
        _logDeployment("AdiAdapter", ADI_ADAPTER_SALT_SEED, adiAdapter);
        return adiAdapter;
    }

    function _deployPriceOracle() internal returns (address) {
        address predicted = getPriceOracleAddress(_deployer());
        bytes memory implCreationCode =
            abi.encodePacked(type(PriceOracle).creationCode, abi.encode(_configUint(".priceOracleMinValidPriceRay")));
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(predicted, implCreationCode, PRICE_ORACLE_PROXY_ADMIN_OWNER, "PriceOracle");
            logSkip("_deployPriceOracle", "PriceOracle");
            _logDeployment("PriceOracle", PRICE_ORACLE_SALT_SEED, predicted);
            return predicted;
        }
        address implementation = address(new PriceOracle(_configUint(".priceOracleMinValidPriceRay")));
        _logDeployment("PriceOracle::Implementation", "", implementation);
        address priceOracle = _deployTransparentProxy_create3({
            namespacedSaltSeed: PRICE_ORACLE_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: PRICE_ORACLE_PROXY_ADMIN_OWNER,
            initCalldata: abi.encodeCall(PriceOracle.initialize, (getAccessManagerAddress(_deployer())))
        });
        require(priceOracle == predicted, "PriceOracle does not match expected address");
        _logDeployment("PriceOracle", PRICE_ORACLE_SALT_SEED, priceOracle);
        return priceOracle;
    }

    function _deployPolicyRegistry() internal returns (address) {
        address predicted = getPolicyRegistryAddress(_deployer());
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedRuntimeCode(predicted, keccak256(type(PolicyRegistry).runtimeCode), "PolicyRegistry");
            logSkip("_deployPolicyRegistry", "PolicyRegistry");
            _logDeployment("PolicyRegistry", POLICY_REGISTRY_SALT_SEED, predicted);
            return predicted;
        }
        address policyRegistry = _deploy_create3({
            namespacedSaltSeed: POLICY_REGISTRY_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(PolicyRegistry).creationCode, abi.encode(getAccessManagerAddress(_deployer()))
            )
        });
        require(policyRegistry == predicted, "PolicyRegistry does not match expected address");
        _logDeployment("PolicyRegistry", POLICY_REGISTRY_SALT_SEED, policyRegistry);
        return policyRegistry;
    }

    function _deployFundsBridgingPolicy() internal returns (address) {
        address predicted = getFundsBridgingPolicyAddress(_deployer());
        bytes memory initCode = abi.encodePacked(
            type(FundsBridgingPolicy).creationCode,
            abi.encode(getAccessManagerAddress(_deployer()), _fundsBridgingPolicyHolder())
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(predicted, initCode, "FundsBridgingPolicy");
            logSkip("_deployFundsBridgingPolicy", "FundsBridgingPolicy");
            _logDeployment("FundsBridgingPolicy", FUNDS_BRIDGING_POLICY_SALT_SEED, predicted);
            return predicted;
        }
        address fundsBridgingPolicy = _deploy_create3({
            namespacedSaltSeed: FUNDS_BRIDGING_POLICY_SALT_SEED, deployer: _deployer(), initCode: initCode
        });
        require(fundsBridgingPolicy == predicted, "FundsBridgingPolicy does not match expected address");
        _logDeployment("FundsBridgingPolicy", FUNDS_BRIDGING_POLICY_SALT_SEED, fundsBridgingPolicy);
        return fundsBridgingPolicy;
    }

    /// @dev Funds-holding contract whose bridging the policy guards (FundsHandler on accounting chain, Gateway on
    /// earning chain).
    function _fundsBridgingPolicyHolder() internal view virtual returns (address);
}
