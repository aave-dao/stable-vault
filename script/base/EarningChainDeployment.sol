// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

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
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {AggregatorV3Interface, ChainlinkPriceOracleAdapter} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {EarningChainStateProvider} from "src/periphery/EarningChainStateProvider.sol";
import {SlippageCoverageVault} from "src/periphery/SlippageCoverageVault.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

abstract contract EarningChainDeployment is Create3Deployment, AccessManagerEarningChainSetup, ATokenVaultDeployment {
    using Strings for address;

    address immutable PROXY_ADMIN_OWNER = getAccessManagerAddress(_deployer());
    address immutable ALLOCATOR_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable WITHDRAWAL_POLICY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable ASSET_REGISTRY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable GATEWAY_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable IOU_TOKEN_MANAGER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable PRICE_ORACLE_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;
    address immutable EARNING_CHAIN_STATE_PROVIDER_PROXY_ADMIN_OWNER = PROXY_ADMIN_OWNER;

    address immutable ACCESS_MANAGER_ADMIN = _deployer();

    address immutable ALLOCATOR_DEPOSITOR = getGatewayAddress(_deployer());
    address immutable ALLOCATOR_WITHDRAWER = getGatewayAddress(_deployer());

    function _gho() internal view returns (address) {
        return _configAddress(".earningChain.assets.gho");
    }

    function _usdc() internal view returns (address) {
        return _configAddress(".earningChain.assets.usdc");
    }

    function _usdt() internal view returns (address) {
        return _configAddress(".earningChain.assets.usdt");
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
        address ghoUsdFeed = _configAddress(".earningChain.chainlinkFeeds.ghoUsd");
        require(ghoUsdFeed != address(0), "Chainlink GHO/USD data feed not set");
        AggregatorV3Interface(ghoUsdFeed).latestRoundData();

        address usdcUsdFeed = _configAddress(".earningChain.chainlinkFeeds.usdcUsd");
        require(usdcUsdFeed != address(0), "Chainlink USDC/USD data feed not set");
        AggregatorV3Interface(usdcUsdFeed).latestRoundData();

        address usdtUsdFeed = _configAddress(".earningChain.chainlinkFeeds.usdtUsd");
        require(usdtUsdFeed != address(0), "Chainlink USDT/USD data feed not set");
        AggregatorV3Interface(usdtUsdFeed).latestRoundData();

        // Validate CCIP router
        require(
            IRouterClient(_configAddress(".earningChain.ccipRouterAddress"))
                .isChainSupported(uint64(vm.parseUint(_configString(".accountingChain.ccipSelector")))),
            "CCIP Router does not support accounting chain"
        );

        // Validate Aave V3 pool addresses provider
        require(
            _configAddress(".earningChain.aaveV3PoolAddressesProvider") != address(0),
            "Aave V3 pool addresses provider not set"
        );

        // Validate withdrawal policy signer
        require(_configAddress(".withdrawalPolicy.signer") != address(0), "Withdrawal policy signer not set");
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
        _deploySlippageCoverageVault();
        _deploySwapper();
        _deployCcipAdapter();
        _deployEarningChainStateProvider();
    }

    function _setupContracts() internal {
        _setupBridgeAdapters();
        _setupAssetRegistry();
        _setupAllocator();
        _setupWithdrawalPolicy();
        _setupPriceOracleAdapters();
        _setupAccessManager(_deployer()); // Must be last – revokes deployer's ADMIN_ROLE
    }

    function _accessManager() internal view virtual override returns (address) {
        return getAccessManagerAddress(_deployer());
    }

    function _setupBridgeAdapters() internal {
        // NOTE: This assumes adapters of same type are having the same address on all chains.
        address localCcipAdapter = getCcipAdapterAddress(_deployer());
        address accountingCcipAdapter = localCcipAdapter;

        IEarningChainGateway gateway = IEarningChainGateway(getGatewayAddress(_deployer()));

        uint256 accountingChainId = _configUint(".accountingChain.chainId");
        uint64 accountingChainCcipSelector = uint64(vm.parseUint(_configString(".accountingChain.ccipSelector")));

        // GHO uses CCIP Adapter
        gateway.addBridgeAdapter(_gho(), accountingChainId, localCcipAdapter);

        // USDC uses CCIP Adapter
        gateway.addBridgeAdapter(_usdc(), accountingChainId, localCcipAdapter);

        // USDT uses CCIP Adapter
        gateway.addBridgeAdapter(_usdt(), accountingChainId, localCcipAdapter);

        // Message uses CCIP Adapter
        address messageOnly = address(0);
        gateway.addBridgeAdapter(messageOnly, accountingChainId, localCcipAdapter);

        ICcipBridgeAdapter(localCcipAdapter).setChainSelector(accountingChainId, accountingChainCcipSelector);
        ICcipBridgeAdapter(localCcipAdapter).setDestinationChainAdapter(accountingChainId, accountingCcipAdapter);
    }

    function _setupWithdrawalPolicy() internal {
        WithdrawalPolicy withdrawalPolicy = WithdrawalPolicy(getWithdrawalPolicyAddress(_deployer()));
        withdrawalPolicy.setDefaultFeeBps(uint16(_configUint(".withdrawalPolicy.defaultFeeBps")));
        withdrawalPolicy.addSigner(_configAddress(".withdrawalPolicy.signer"));
    }

    function _setupAllocator() internal {
        IAllocator allocator = IAllocator(getAllocatorAddress(_deployer()));
        address poolAddressProvider = _configAddress(".earningChain.aaveV3PoolAddressesProvider");

        address usdcYieldStrategy =
            _deployATokenVault(_usdc(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        allocator.addStrategy(_usdc(), usdcYieldStrategy);
        allocator.setDefaultStrategy(_usdc(), usdcYieldStrategy);

        address usdtYieldStrategy =
            _deployATokenVault(_usdt(), poolAddressProvider, getAccessManagerAddress(_deployer()), _deployer());
        allocator.addStrategy(_usdt(), usdtYieldStrategy);
        allocator.setDefaultStrategy(_usdt(), usdtYieldStrategy);
    }

    function _deployedATokenVaultAddresses() internal view virtual override returns (address[] memory) {
        return _readATokenVaultAddresses(_configString(".earningChain.deploymentOutputPath"));
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
                maxStrategiesPerAsset: uint8(_configUint(".maxStrategiesPerAsset"))
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
                accountingChainId: _configUint(".accountingChain.chainId"),
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

    function _deploySlippageCoverageVault() internal returns (address) {
        // Non-upgradeable. Bound to the predicted Swapper address (deployed next, same script).
        address slippageCoverageVault = _deploy_create3({
            namespacedSaltSeed: SLIPPAGE_COVERAGE_VAULT_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(SlippageCoverageVault).creationCode,
                abi.encode(
                    getSwapperAddress(_deployer()),
                    getAccessManagerAddress(_deployer()),
                    uint16(vm.parseUint(_configString(".slippageCoverageVault.maxSlippageBps"))),
                    uint16(vm.parseUint(_configString(".slippageCoverageVault.overrideMaxSlippageBps")))
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
                    _configAddress(".earningChain.ccipRouterAddress"),
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
        address implementation = address(new PriceOracle(vm.parseUint(_configString(".priceOracleMinValidPriceRay"))));
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
        address implementation = address(new EarningChainStateProvider(getGatewayAddress(_deployer())));
        _logDeployment("EarningChainStateProvider::Implementation", "", implementation);
        address earningChainStateProvider = _deployTransparentProxy_create3({
            namespacedSaltSeed: EARNING_CHAIN_STATE_PROVIDER_SALT_SEED,
            deployer: _deployer(),
            implementation: implementation,
            proxyAdminOwner: EARNING_CHAIN_STATE_PROVIDER_PROXY_ADMIN_OWNER,
            initCalldata: ""
        });
        require(
            earningChainStateProvider == getEarningChainStateProviderAddress(_deployer()),
            "EarningChainStateProvider does not match expected address"
        );
        _logDeployment("EarningChainStateProvider", EARNING_CHAIN_STATE_PROVIDER_SALT_SEED, earningChainStateProvider);
        return earningChainStateProvider;
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

        address ghoAdapter = address(
            new ChainlinkPriceOracleAdapter(_gho(), _configAddress(".earningChain.chainlinkFeeds.ghoUsd"), heartbeat)
        );
        _logDeployment("ChainlinkPriceOracleAdapter::GHO", "", ghoAdapter);
        priceOracle.setOracleAdapterForAsset(_gho(), ghoAdapter);

        address usdcAdapter = address(
            new ChainlinkPriceOracleAdapter(_usdc(), _configAddress(".earningChain.chainlinkFeeds.usdcUsd"), heartbeat)
        );
        _logDeployment("ChainlinkPriceOracleAdapter::USDC", "", usdcAdapter);
        priceOracle.setOracleAdapterForAsset(_usdc(), usdcAdapter);

        address usdtAdapter = address(
            new ChainlinkPriceOracleAdapter(_usdt(), _configAddress(".earningChain.chainlinkFeeds.usdtUsd"), heartbeat)
        );
        _logDeployment("ChainlinkPriceOracleAdapter::USDT", "", usdtAdapter);
        priceOracle.setOracleAdapterForAsset(_usdt(), usdtAdapter);
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal virtual override {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, _configString(".earningChain.deploymentOutputPath"), string.concat(".", name));
    }

    function _logATokenVaultDeployments() internal override {
        vm.writeJson(_buildATokenVaultsJson(), _configString(".earningChain.deploymentOutputPath"), ".aTokenVaults");
    }
}
