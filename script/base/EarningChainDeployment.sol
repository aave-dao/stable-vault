// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {AccessManagerEarningChainSetup} from "script/base/AccessManagerEarningChainSetup.sol";
import {BaseChainDeployment} from "script/base/BaseChainDeployment.sol";
import {logSkip} from "script/libraries/DeploymentLogLib.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {AggregatorV3Interface, ChainlinkPriceOracleAdapter} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {EarningChainStateProvider} from "src/periphery/EarningChainStateProvider.sol";

abstract contract EarningChainDeployment is BaseChainDeployment, AccessManagerEarningChainSetup {
    address immutable EARNING_CHAIN_STATE_PROVIDER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;

    // keccak256("aave.stable-vault.EarningChainGateway.policy.withdrawal-execution")
    bytes32 internal constant EARNING_WITHDRAWAL_EXECUTION_POLICY_ID =
        0xf213893b1e253163c05de458d1c9283d3155b096d439aab98ea90b491dce4bfb;
    // keccak256("aave.stable-vault.EarningChainGateway.policy.bridge")
    bytes32 internal constant EARNING_BRIDGE_POLICY_ID =
        0x537fb58e71f5b54dc09d8afff5cbf9bf5e630233f65f0531590f8cfa4a81bc6c;

    // Keep field order aligned with Foundry's JSON object encoding order.
    struct ExistingErc4626StrategyConfig {
        address addr;
        string assetSymbol;
        string strategySymbol;
        address underlyingAddress;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // BaseChainDeployment hooks.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _chainConfigPrefix() internal pure override returns (string memory) {
        return ".earningChain";
    }

    function _remoteChainConfigPrefix() internal pure override returns (string memory) {
        return ".accountingChain";
    }

    function _chainName() internal pure override returns (string memory) {
        return "earning-chain";
    }

    function _withdrawalExecutionPolicyId() internal pure override returns (bytes32) {
        return EARNING_WITHDRAWAL_EXECUTION_POLICY_ID;
    }

    function _bridgePolicyId() internal pure override returns (bytes32) {
        return EARNING_BRIDGE_POLICY_ID;
    }

    function _withdrawalExecutionPolicyTarget() internal view override returns (address) {
        return getGatewayAddress(_deployer());
    }

    function _iouTokenManagerVault() internal pure override returns (address) {
        return address(0);
    }

    function _isAccountingChain() internal pure override returns (bool) {
        return false;
    }

    function _allocatorDepositor() internal view override returns (address) {
        return getGatewayAddress(_deployer());
    }

    function _allocatorWithdrawer() internal view override returns (address) {
        return getGatewayAddress(_deployer());
    }

    function _fundsBridgingPolicyHolder() internal view override returns (address) {
        return getGatewayAddress(_deployer());
    }

    function _validateChainSpecificDeploymentParameters() internal view override {
        require(_configUint(".earningChain.minBurnIouTokenGasLimit") > 0, "minBurnIouTokenGasLimit must be > 0");
    }

    function _validateChainSpecificExternalAddresses() internal view override {
        _validateExistingErc4626Strategies();
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

    function _isAdiAdapterDeployed()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, BaseChainDeployment)
        returns (bool)
    {
        return BaseChainDeployment._isAdiAdapterDeployed();
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

    function _setup_Targets(address deployer)
        internal
        virtual
        override(AccessManagerBaseSetup, AccessManagerEarningChainSetup)
    {
        AccessManagerEarningChainSetup._setup_Targets(deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Deploy / setup orchestration.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _deployContracts() internal override {
        _deployTransferHelper();
        _deployAccessManager();
        _deployAssetRegistry();
        _deployPolicyRegistry();
        _deployWithdrawalExecutionPolicy();
        _deployIouToken();
        _deployIouTokenManager();
        _deployPriceOracle();
        _deployAllocator();
        _deployGateway();
        _deploySlippageCoverageVault();
        _deploySwapper();
        _deployCcipAdapter();
        _deployAdiAdapter();
        _deployEarningChainStateProvider();
        _deployFundsBridgingPolicy();
    }

    function _setupContracts() internal override {
        _setupBridgeAdapters();
        _setupAssetRegistry();
        _setupAllocator();
        _setupWithdrawalExecutionPolicy();
        _setupPriceOracleAdapters();
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

    function _deployGateway() internal returns (address) {
        address predicted = getGatewayAddress(_deployer());
        bytes memory implCreationCode = abi.encodePacked(
            type(EarningChainGateway).creationCode,
            abi.encode(
                _configUint(".accountingChain.chainId"),
                getAllocatorAddress(_deployer()),
                getPriceOracleAddress(_deployer()),
                getIouTokenManagerAddress(_deployer()),
                getTransferHelperAddress(_deployer()),
                getPolicyRegistryAddress(_deployer()),
                _configUint(".earningChain.minBurnIouTokenGasLimit")
            )
        );
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(predicted, implCreationCode, "EarningChainGateway");
            logSkip("_deployGateway", "EarningChainGateway");
            _logDeployment("EarningChainGateway", GATEWAY_SALT_SEED, predicted);
            return predicted;
        }
        address implementation = address(
            new EarningChainGateway({
                accountingChainId: _configUint(".accountingChain.chainId"),
                allocator: getAllocatorAddress(_deployer()),
                priceOracle: getPriceOracleAddress(_deployer()),
                iouTokenManager: getIouTokenManagerAddress(_deployer()),
                transferHelper: getTransferHelperAddress(_deployer()),
                policyRegistry: getPolicyRegistryAddress(_deployer()),
                minBurnIouTokenGasLimit: _configUint(".earningChain.minBurnIouTokenGasLimit")
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
        require(gateway == predicted, "Gateway does not match expected address");
        _logDeployment("EarningChainGateway", GATEWAY_SALT_SEED, gateway);
        return gateway;
    }

    function _deployEarningChainStateProvider() internal returns (address) {
        address predicted = getEarningChainStateProviderAddress(_deployer());
        bytes memory implCreationCode =
            abi.encodePacked(type(EarningChainStateProvider).creationCode, abi.encode(getGatewayAddress(_deployer())));
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedTransparentProxy(predicted, implCreationCode, "EarningChainStateProvider");
            logSkip("_deployEarningChainStateProvider", "EarningChainStateProvider");
            _logDeployment("EarningChainStateProvider", EARNING_CHAIN_STATE_PROVIDER_SALT_SEED, predicted);
            return predicted;
        }
        address implementation = address(new EarningChainStateProvider(getGatewayAddress(_deployer())));
        _logDeployment("EarningChainStateProvider::Implementation", "", implementation);
        address earningChainStateProvider = _deployTransparentProxy_create3({
            namespacedSaltSeed: EARNING_CHAIN_STATE_PROVIDER_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: EARNING_CHAIN_STATE_PROVIDER_PROXY_ADMIN_OWNER,
            initCalldata: ""
        });
        require(earningChainStateProvider == predicted, "EarningChainStateProvider does not match expected address");
        _logDeployment("EarningChainStateProvider", EARNING_CHAIN_STATE_PROVIDER_SALT_SEED, earningChainStateProvider);
        return earningChainStateProvider;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Chain-specific setups.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupAllocator() internal {
        IAllocator allocator = IAllocator(getAllocatorAddress(_deployer()));
        address poolAddressProvider = _configAddress(".earningChain.aaveV3PoolAddressesProvider");

        ExistingErc4626StrategyConfig[] memory existingStrategies = _existingErc4626Strategies();
        for (uint256 i = 0; i < existingStrategies.length; i++) {
            // These are existing ERC4626 vaults, not aTokenVaults deployed by this script.
            _addStrategyIdempotent(allocator, existingStrategies[i].underlyingAddress, existingStrategies[i].addr);
        }

        address usdcYieldStrategy =
            _deployATokenVault(_usdc(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        _addStrategyIdempotent(allocator, _usdc(), usdcYieldStrategy);

        address usdtYieldStrategy =
            _deployATokenVault(_usdt(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        _addStrategyIdempotent(allocator, _usdt(), usdtYieldStrategy);
    }

    function _setupPriceOracleAdapters() internal {
        // Using plain ChainlinkPriceOracleAdapter (no sequencer uptime feed check) because the
        // Earning Chain is currently on Ethereum mainnet. If we ever deploy on an L2, we might need to use
        // ChainlinkL2PriceOracleAdapter with sequencer uptime feed instead.
        // This require aims to force the deployer to consider the usage of ChainlinkL2PriceOracleAdapter.
        // If deployer decides it is not needed, the require can be commented out or removed in order to proceed.
        require(block.chainid == 1, "Consider using ChainlinkL2PriceOracleAdapter with sequencer uptime feed");

        PriceOracle priceOracle = PriceOracle(getPriceOracleAddress(_deployer()));
        uint256 heartbeat = _configUint(".chainlinkPriceOracleHeartbeat");

        _wireChainlinkPriceOracleAdapter(
            priceOracle, _gho(), _configAddress(".earningChain.chainlinkFeeds.ghoUsd"), heartbeat, "GHO"
        );
        _wireChainlinkPriceOracleAdapter(
            priceOracle, _usdc(), _configAddress(".earningChain.chainlinkFeeds.usdcUsd"), heartbeat, "USDC"
        );
        _wireChainlinkPriceOracleAdapter(
            priceOracle, _usdt(), _configAddress(".earningChain.chainlinkFeeds.usdtUsd"), heartbeat, "USDT"
        );
    }

    function _wireChainlinkPriceOracleAdapter(
        PriceOracle priceOracle,
        address asset,
        address feed,
        uint256 heartbeat,
        string memory assetSymbol
    ) private {
        string memory saltSeed = getChainlinkPriceOracleAdapterSaltSeed(asset);
        address predicted = getChainlinkPriceOracleAdapterAddress(asset, _deployer());
        bytes memory initCode =
            abi.encodePacked(type(ChainlinkPriceOracleAdapter).creationCode, abi.encode(asset, feed, heartbeat));
        address adapter;
        if (predicted.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertDeployedMatchesReference(
                predicted, initCode, string.concat("ChainlinkPriceOracleAdapter::", assetSymbol)
            );
            adapter = predicted;
            logSkip("_wireChainlinkPriceOracleAdapter", string.concat("adapter for ", assetSymbol));
        } else {
            adapter = _deploy_create3({namespacedSaltSeed: saltSeed, deployer: _deployer(), initCode: initCode});
            require(adapter == predicted, "ChainlinkPriceOracleAdapter does not match expected address");
        }
        _logDeployment(string.concat("ChainlinkPriceOracleAdapter::", assetSymbol), saltSeed, adapter);
        /// @custom:tx-already-executed-check Oracle already wired to this adapter.
        if (priceOracle.getOracleAdapterForAsset(asset) != adapter) {
            priceOracle.setOracleAdapterForAsset(asset, adapter);
        } else {
            logSkip("_wireChainlinkPriceOracleAdapter", string.concat("oracle wiring for ", assetSymbol));
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // ERC4626 strategy validation.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _existingErc4626Strategies() internal view returns (ExistingErc4626StrategyConfig[] memory) {
        bytes memory raw = vm.parseJson(_readConfig(), ".earningChain.erc4626Strategies");
        return abi.decode(raw, (ExistingErc4626StrategyConfig[]));
    }

    function _validateExistingErc4626Strategies() private view {
        ExistingErc4626StrategyConfig[] memory existingStrategies = _existingErc4626Strategies();
        bool ghoStrategyConfigured = false;

        for (uint256 i = 0; i < existingStrategies.length; i++) {
            ExistingErc4626StrategyConfig memory strategy = existingStrategies[i];
            address asset = _assetAddressFromSymbol(strategy.assetSymbol);

            require(strategy.addr != address(0), "ERC4626 strategy not set");
            require(strategy.underlyingAddress != address(0), "ERC4626 underlying not set");
            require(strategy.underlyingAddress == asset, "ERC4626 underlying config mismatch");
            require(IERC4626(strategy.addr).asset() == strategy.underlyingAddress, "ERC4626 underlying mismatch");
            require(
                keccak256(bytes(IERC4626(strategy.addr).symbol())) == keccak256(bytes(strategy.strategySymbol)),
                "ERC4626 strategy symbol mismatch"
            );

            if (strategy.underlyingAddress == _gho()) {
                ghoStrategyConfigured = true;
            }
        }

        require(ghoStrategyConfigured, "GHO ERC4626 strategy not set");
    }

    function _assetAddressFromSymbol(string memory assetSymbol) private view returns (address) {
        bytes32 symbolHash = keccak256(bytes(assetSymbol));
        if (symbolHash == keccak256("GHO")) {
            return _gho();
        }
        if (symbolHash == keccak256("USDC")) {
            return _usdc();
        }
        if (symbolHash == keccak256("USDT")) {
            return _usdt();
        }
        revert("unsupported ERC4626 asset symbol");
    }
}
