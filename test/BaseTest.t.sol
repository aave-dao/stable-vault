// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AccessManager} from "openzeppelin-contracts/contracts/access/manager/AccessManager.sol";

import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {Allocator} from "src/core/Allocator.sol";
import {AccountingChainGateway} from "src/core/accounting/AccountingChainGateway.sol";
import {BasedBoostedVault} from "src/core/accounting/BasedBoostedVault.sol";
import {BasedBoostedVault} from "src/core/accounting/BasedBoostedVault.sol";
import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBasedBoostedVault} from "src/interfaces/IBasedBoostedVault.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {EarningChainStateProvider_V1} from "src/periphery/EarningChainStateProvider_V1.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {ChainlinkChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkChainBalanceOracleAdapter.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {_toSelectorArray} from "test/helpers/TypeHelpers.sol";
import {EarningChainStateProviderHarness} from "test/mocks/EarningChainStateProviderHarness.sol";
import {MockBundleFeed} from "test/mocks/MockBundleFeed.sol";
import {MockCCIPRouter} from "test/mocks/MockCcipRouter.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {TestErc4626} from "test/mocks/TestErc4626.sol";

contract BaseTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;

    address proxyAdmin = makeAddr("PROXY_ADMIN");
    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    uint8 constant STRATEGY_MAX_SLIPPAGE_AMOUNT = 10;
    /// @dev Must match EarningChainStateProvider_V1.VERSION (contract constant not visible on type in Solidity).
    uint256 internal constant EARNING_CHAIN_STATE_VERSION = 1;

    // ADMIN_ROLE = 0
    uint64 internal constant ROLE_MANAGEMENT_ROLE = 1;
    uint64 internal constant GUARDIAN_ROLE = 2;
    uint64 internal constant UPGRADE_PROXY_ADMIN_ROLE = 3;
    uint64 internal constant APPENDER_ROLE = 4;
    uint64 internal constant REMOVER_ROLE = 5;
    uint64 internal constant RESCUER_ROLE = 6;
    uint64 internal constant PROFIT_TAKER_ROLE = 7;
    uint64 internal constant OPERATOR_ROLE = 8;

    uint256 initialBasePerSecondRate = MathLib.RAY; // 1 RAY

    uint8 internal constant MAX_STRATEGIES_PER_ASSET = 15;
    uint256 internal constant DEFAULT_MAX_ACTIVE_SUB_VAULTS = 201;
    uint64 internal constant ACCOUNTING_CHAIN_ID = 1;
    uint64 internal constant ACCOUNTING_CHAIN_CCIP_SELECTOR = 10;
    uint64 internal constant EARNING_CHAIN_ID = 2;
    uint64 internal constant EARNING_CHAIN_CCIP_SELECTOR = 20;
    uint256 internal constant CHAIN_BALANCE_ORACLE_HEARTBEAT_SECONDS = 3600;
    uint256 internal constant CHAIN_BALANCE_ORACLE_PUBLISH_BUFFER_SECONDS = 90;

    // Transfer Helper
    address transferHelper_accountingChainAddress;
    address transferHelper_earningChainAddress;

    // Currencies
    MockErc20 GHO = new MockErc20("Test GHO", "tGHO", 18);
    MockErc20 USDC = new MockErc20("Test USDC", "tUSDC", 6);

    // Accounting Chain: BBV, FH, Swapper, Allocator, Accounting Chain Gateway, CCIP Adapter, CCIP Router, Strategy
    // Vault/4626
    address accessManager_accountingChainAddress;
    address vault_accountingChainAddress;
    address iouToken_accountingChainAddress;
    address iouTokenManager_accountingChainAddress;
    address assetRegistry_accountingChainAddress;
    address withdrawalPolicy_accountingChainAddress;
    address fundsHandler_accountingChainAddress;
    address allocator_accountingChainAddress;
    address swapper_accountingChainAddress;
    address chainGateway_accountingChainAddress;
    address ccipAdapter_accountingChainAddress;
    address ghoStrategyVault_accountingChainAddress;
    address usdcStrategyVault_accountingChainAddress;
    AccessManager accessManager_accountingChain;
    BasedBoostedVault vault;
    IouToken iouToken_accountingChain;
    IouTokenManager iouTokenManager_accountingChain;
    AssetRegistry assetRegistry_accountingChain;
    WithdrawalPolicy withdrawalPolicy_accountingChain;
    FundsHandler fundsHandler;
    Allocator allocator_accountingChain;
    Swapper swapper_accountingChain;
    AccountingChainGateway accountingChainGateway;
    CcipAdapter ccipAdapter_accountingChain;
    TestErc4626 ghoStrategyVault_accountingChain;
    TestErc4626 usdcStrategyVault_accountingChain;

    // Earning Chain: Earning Chain Gateway, CCIP Adapter, CCIP Router, Swapper, Allocator, Strategy Vault/4626
    address accessManager_earningChainAddress;
    address assetRegistry_earningChainAddress;
    address withdrawalPolicy_earningChainAddress;
    address iouToken_earningChainAddress;
    address iouTokenManager_earningChainAddress;
    address ccipAdapter_earningChainAddress;
    address chainGateway_earningChainAddress;
    address allocator_earningChainAddress;
    address swapper_earningChainAddress;
    address ghoStrategyVault_earningChainAddress;
    address usdcStrategyVault_earningChainAddress;
    AccessManager accessManager_earningChain;
    AssetRegistry assetRegistry_earningChain;
    WithdrawalPolicy withdrawalPolicy_earningChain;
    IouToken iouToken_earningChain;
    IouTokenManager iouTokenManager_earningChain;
    CcipAdapter ccipAdapter_earningChain;
    EarningChainGateway earningChainGateway;
    Allocator allocator_earningChain;
    Swapper swapper_earningChain;
    TestErc4626 ghoStrategyVault_earningChain;
    TestErc4626 usdcStrategyVault_earningChain;

    // Mock CCIP Router
    MockCCIPRouter public mockCcipRouter;

    // Price Oracles
    PriceOracle public priceOracle_accountingChain;
    PriceOracle public priceOracle_earningChain;

    // Chain Balance Oracle + adapter/feed wiring used by E2E tests
    ChainBalanceOracle public chainBalanceOracle;
    IEarningChainStateProvider public earningChainStateProvider;
    MockBundleFeed public mockBundleFeed;
    ChainlinkChainBalanceOracleAdapter public chainBalanceOracleAdapter;

    function _useMockedPriceOracleAccountingChain() internal view virtual returns (bool) {
        return true;
    }

    function _useMockedPriceOracleEarningChain() internal view virtual returns (bool) {
        return true;
    }

    function _prepareTokens() internal {
        GHO.mint(address(this), 10000 ether);
        USDC.mint(address(this), 10000 * (10 ** 6));

        GHO.approve(address(ghoStrategyVault_accountingChain), 1000 ether);
        USDC.approve(address(usdcStrategyVault_accountingChain), 1000 * (10 ** 6));
        GHO.approve(address(ghoStrategyVault_earningChain), 1000 ether);
        USDC.approve(address(usdcStrategyVault_earningChain), 1000 * (10 ** 6));

        ghoStrategyVault_accountingChain.deposit(1000 ether, address(this));
        usdcStrategyVault_accountingChain.deposit(1000 * (10 ** 6), address(this));
        ghoStrategyVault_earningChain.deposit(1000 ether, address(this));
        usdcStrategyVault_earningChain.deposit(1000 * (10 ** 6), address(this));
    }

    function _deployBasedBoostedVault(
        address accessManager,
        uint256 maxPerSecondRate,
        uint256 defaultSubVaultPerSecondRate,
        address iouTokenManager,
        address fundsHandlerAddr,
        address assetRegistry,
        address transferHelper,
        address withdrawalFeeCalculator,
        address priceOracle,
        uint256 maxActiveSubVaults
    ) internal virtual returns (BasedBoostedVault) {
        address vaultImpl = address(
            new BasedBoostedVault(
                maxPerSecondRate,
                assetRegistry,
                iouTokenManager,
                fundsHandlerAddr,
                transferHelper,
                withdrawalFeeCalculator,
                priceOracle,
                maxActiveSubVaults
            )
        );

        address bbv = address(
            new TransparentUpgradeableProxy(
                vaultImpl,
                address(this),
                abi.encodeCall(BasedBoostedVault.initialize, (accessManager, defaultSubVaultPerSecondRate))
            )
        );

        vm.label(bbv, "BBV");

        return BasedBoostedVault(bbv);
    }

    function _deployContracts() internal {
        console.log("\n-------------------");
        console.log("\nDeploying contracts");
        console.log("\nEvery Role Account: %s", everyRoleAccount);
        console.log("\tAdmin: %s", admin);
        console.log("\tInitial Base Per Second Rate: %s", initialBasePerSecondRate);
        console.log("\tAccounting Chain ID: %s", ACCOUNTING_CHAIN_ID);
        console.log("\tEarning Chain ID: %s", EARNING_CHAIN_ID);

        // ccip mock
        mockCcipRouter = new MockCCIPRouter();
        console.log("\tMock CCIP Router: %s", address(mockCcipRouter));

        mockCcipRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        mockCcipRouter.setSourceChainSelector(ACCOUNTING_CHAIN_CCIP_SELECTOR, EARNING_CHAIN_CCIP_SELECTOR);

        // Chain balance oracle for tracking earning chain balances from accounting chain.
        // Deployed after the Access Manager is deployed.

        console.log("\nAccounting Chain:");
        // ---- Accounting Chain ----
        // Accounting Chain: BBV, FH, Swapper, Allocator, Accounting Chain Gateway, CCIP Adapter, CCIP Router, Strategy,
        // Asset Registry Vault/4626

        // Deployment order:
        // 1. Access Manager
        // 2. Asset Registry Impl
        // 3. Asset Registry Proxy
        // 4. Withdrawal Policy Impl
        // 5. Withdrawal Policy Proxy
        // 6. IOU Token
        // 7. IOU Token Manager Impl
        // 8. IOU Token Manager Proxy
        // 9. Based Boosted Vault Impl
        // 10. Based Boosted Vault Proxy
        // 11. Allocator Impl
        // 12. Allocator Proxy
        // 13. Funds Handler Impl
        // 14. Funds Handler Proxy
        // 15. Accounting Chain Gateway Impl
        // 16. Accounting Chain Gateway Proxy
        // 17. Swapper
        // 18. CCIP Adapter
        // 19. Strategy Vault/4626

        transferHelper_accountingChainAddress = address(new TransferHelper());

        // Pre compute addresses for contracts that are with circular dependencies
        uint256 deployerNonce_accountingChain = vm.getNonce(address(this));
        console.log("\tDeployer Nonce (Accounting Chain): %s", deployerNonce_accountingChain);

        accessManager_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tAccess Manager (Accounting Chain) Predicted Address: %s", accessManager_accountingChainAddress);

        deployerNonce_accountingChain += 2; // Incrementing for Chain Balance Oracle implementation + proxy
        deployerNonce_accountingChain += 2; // Incrementing for Price Oracle implementation + proxy

        deployerNonce_accountingChain++; // Incrementing for Asset Registry implementation
        assetRegistry_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tAsset Registry (Accounting Chain) Predicted Address: %s", assetRegistry_accountingChainAddress);

        deployerNonce_accountingChain++; // Incrementing for Withdrawal Policy implementation
        withdrawalPolicy_accountingChainAddress =
            vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log(
            "\tWithdrawal Policy (Accounting Chain) Predicted Address: %s", withdrawalPolicy_accountingChainAddress
        );

        iouToken_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tIOU Token (Accounting Chain) Predicted Address: %s", iouToken_accountingChainAddress);

        deployerNonce_accountingChain++; // Incrementing for IOU TokenManager implementation
        iouTokenManager_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log(
            "\tIOU Token Manager (Accounting Chain) Predicted Address: %s", iouTokenManager_accountingChainAddress
        );

        deployerNonce_accountingChain++; // Incrementing for BBV implementation
        vault_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tVault (Accounting Chain) Predicted Address: %s", vault_accountingChainAddress);

        deployerNonce_accountingChain++; // Incrementing for Allocator implementation
        allocator_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tAllocator (Accounting Chain) Predicted Address: %s", allocator_accountingChainAddress);

        deployerNonce_accountingChain++; // Incrementing for FH implementation
        fundsHandler_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tFunds Handler (Accounting Chain) Predicted Address: %s", fundsHandler_accountingChainAddress);
        vm.label(fundsHandler_accountingChainAddress, "FundsHandler");

        deployerNonce_accountingChain++; // Incrementing for Gateway implementation
        chainGateway_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log(
            "\tAccounting Chain Gateway (Accounting Chain) Predicted Address: %s", chainGateway_accountingChainAddress
        );

        swapper_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tSwapper (Accounting Chain) Predicted Address: %s", swapper_accountingChainAddress);

        ccipAdapter_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tCCIP Adapter (Accounting Chain) Predicted Address: %s", ccipAdapter_accountingChainAddress);

        // 1. Access Manager
        accessManager_accountingChain = new AccessManager(admin);
        console.log("\tAccess Manager: %s", address(accessManager_accountingChain));
        require(
            address(accessManager_accountingChain) == accessManager_accountingChainAddress,
            "Access Manager (Accounting Chain) address mismatch"
        );

        chainBalanceOracle = _deployChainBalanceOracle(accessManager_accountingChainAddress);
        console.log("\tChain Balance Oracle (Accounting Chain): %s", address(chainBalanceOracle));

        // Deploy Price Oracle for Accounting Chain (with mocked prices via vm.mockCall)
        priceOracle_accountingChain = _deployPriceOracle(accessManager_accountingChainAddress, 9_995e23);
        console.log("\tPrice Oracle (Accounting Chain): %s", address(priceOracle_accountingChain));
        if (_useMockedPriceOracleAccountingChain()) {
            _mockAssetPrice(address(priceOracle_accountingChain), address(GHO), MathLib.RAY);
            _mockAssetPrice(address(priceOracle_accountingChain), address(USDC), MathLib.RAY);
            _mockValidatePriceForAll(address(priceOracle_accountingChain));
        }

        // 2. Asset Registry
        address assetRegistry_accountingChain_impl = address(new AssetRegistry());
        assetRegistry_accountingChain = AssetRegistry(
            address(
                new TransparentUpgradeableProxy(
                    assetRegistry_accountingChain_impl,
                    proxyAdmin,
                    abi.encodeCall(AssetRegistry.initialize, (accessManager_accountingChainAddress))
                )
            )
        );
        console.log("\tAsset Registry: %s", address(assetRegistry_accountingChain));
        require(
            address(assetRegistry_accountingChain) == assetRegistry_accountingChainAddress,
            "Asset Registry (Accounting Chain) address mismatch"
        );

        // 3. Withdrawal Policy
        address withdrawalPolicy_accountingChain_impl =
            address(new WithdrawalPolicy(assetRegistry_accountingChainAddress, vault_accountingChainAddress));
        withdrawalPolicy_accountingChain = WithdrawalPolicy(
            address(
                new TransparentUpgradeableProxy(
                    withdrawalPolicy_accountingChain_impl,
                    proxyAdmin,
                    abi.encodeCall(WithdrawalPolicy.initialize, (accessManager_accountingChainAddress, 0))
                )
            )
        );
        console.log("\tWithdrawal Policy (Accounting Chain): %s", address(withdrawalPolicy_accountingChain));
        require(
            address(withdrawalPolicy_accountingChain) == withdrawalPolicy_accountingChainAddress,
            "Withdrawal Policy (Accounting Chain) address mismatch"
        );

        // 4. IOU Token
        iouToken_accountingChain = new IouToken(iouTokenManager_accountingChainAddress);
        console.log("\tIOU Token (Accounting Chain): %s", iouToken_accountingChainAddress);
        require(
            address(iouToken_accountingChain) == iouToken_accountingChainAddress,
            "IOU Token (Accounting Chain) address mismatch"
        );

        // 5. IOU Token Manager
        address iouTokenManager_accountingChain_impl = address(
            new IouTokenManager(
                iouToken_accountingChainAddress,
                chainGateway_accountingChainAddress,
                vault_accountingChainAddress,
                transferHelper_accountingChainAddress,
                true
            )
        );
        iouTokenManager_accountingChain = IouTokenManager(
            address(new TransparentUpgradeableProxy(iouTokenManager_accountingChain_impl, proxyAdmin, ""))
        );
        console.log("\tIOU Token Manager (Accounting Chain): %s", address(iouTokenManager_accountingChain));
        require(
            address(iouTokenManager_accountingChain) == iouTokenManager_accountingChainAddress,
            "IOU Token Manager (Accounting Chain) address mismatch"
        );

        // 6. Based Boosted Vault
        // Impl and proxy deployed in the internal `_deployBasedBoostedVault` function
        vault = _deployBasedBoostedVault(
            accessManager_accountingChainAddress,
            DEFAULT_MAX_PER_SECOND_RATE,
            initialBasePerSecondRate,
            iouTokenManager_accountingChainAddress,
            fundsHandler_accountingChainAddress,
            assetRegistry_accountingChainAddress,
            transferHelper_accountingChainAddress,
            withdrawalPolicy_accountingChainAddress,
            address(priceOracle_accountingChain),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS
        );
        console.log("\tVault: %s", vault_accountingChainAddress);
        require(address(vault) == vault_accountingChainAddress, "Vault (Accounting Chain) address mismatch");

        // 6. Allocator
        address allocator_accountingChain_impl = address(
            new Allocator(
                assetRegistry_accountingChainAddress,
                fundsHandler_accountingChainAddress,
                fundsHandler_accountingChainAddress,
                address(priceOracle_accountingChain),
                transferHelper_accountingChainAddress,
                MAX_STRATEGIES_PER_ASSET
            )
        );
        allocator_accountingChain = Allocator(
            address(
                new TransparentUpgradeableProxy(
                    allocator_accountingChain_impl,
                    proxyAdmin,
                    abi.encodeCall(Allocator.initialize, (accessManager_accountingChainAddress))
                )
            )
        );
        console.log("\tAllocator: %s", allocator_accountingChainAddress);
        require(
            address(allocator_accountingChain) == allocator_accountingChainAddress,
            "Allocator (Accounting Chain) address mismatch"
        );

        // 7. Funds Handler
        address fundsHandler_impl = address(
            new FundsHandler(
                vault_accountingChainAddress,
                chainGateway_accountingChainAddress,
                allocator_accountingChainAddress,
                address(priceOracle_accountingChain),
                transferHelper_accountingChainAddress,
                address(chainBalanceOracle)
            )
        );
        fundsHandler = FundsHandler(
            address(
                new TransparentUpgradeableProxy(
                    fundsHandler_impl,
                    proxyAdmin,
                    abi.encodeCall(FundsHandler.initialize, (accessManager_accountingChainAddress))
                )
            )
        );
        console.log("\tFunds Handler: %s", address(fundsHandler));
        require(
            address(fundsHandler) == fundsHandler_accountingChainAddress,
            "Funds Handler (Accounting Chain) address mismatch"
        );

        // 8. Accounting Chain Gateway
        address accountingChainGateway_impl = address(
            new AccountingChainGateway(
                fundsHandler_accountingChainAddress, iouTokenManager_accountingChainAddress, address(chainBalanceOracle)
            )
        );
        accountingChainGateway = AccountingChainGateway(
            address(
                new TransparentUpgradeableProxy(
                    accountingChainGateway_impl,
                    proxyAdmin,
                    abi.encodeCall(AccountingChainGateway.initialize, (accessManager_accountingChainAddress))
                )
            )
        );
        console.log("\tAccounting Chain Gateway: %s", address(accountingChainGateway));
        require(
            address(accountingChainGateway) == chainGateway_accountingChainAddress,
            "Accounting Chain Gateway (Accounting Chain) address mismatch"
        );

        // 9. Swapper
        swapper_accountingChain = new Swapper(allocator_accountingChainAddress);
        console.log("\tSwapper: %s", address(swapper_accountingChain));
        require(
            address(swapper_accountingChain) == swapper_accountingChainAddress,
            "Swapper (Accounting Chain) address mismatch"
        );

        // 10. CCIP Adapter
        ccipAdapter_accountingChain = new CcipAdapter(
            accessManager_accountingChainAddress,
            chainGateway_accountingChainAddress,
            address(mockCcipRouter),
            transferHelper_accountingChainAddress
        );
        console.log("\tCCIP Adapter: %s", address(ccipAdapter_accountingChain));
        require(
            address(ccipAdapter_accountingChain) == ccipAdapter_accountingChainAddress,
            "CCIP Adapter (Accounting Chain) address mismatch"
        );

        // 11. Strategy Vault/4626
        ghoStrategyVault_accountingChain = new TestErc4626(GHO);
        console.log("\tGHO Strategy Vault (Accounting Chain): %s", address(ghoStrategyVault_accountingChain));
        usdcStrategyVault_accountingChain = new TestErc4626(USDC);
        console.log("\tUSDC Strategy Vault (Accounting Chain): %s", address(usdcStrategyVault_accountingChain));

        // /////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Earning Chain: Access Manager, Earning Chain Gateway, CCIP Adapter, CCIP Router, Swapper, Allocator, Strategy
        // Vault/4626, Asset Registry

        console.log("\nEarning Chain:");

        // Deployment order:
        // 1. Access Manager
        // 2. Asset Registry Impl
        // 3. Asset Registry Proxy
        // 4. Withdrawal Policy Impl
        // 5. Withdrawal Policy Proxy
        // 3. CCIP Router
        // 6. IOU Token
        // 7. IOU Token Manager Impl
        // 8. IOU Token Manager Proxy
        // 9. Allocator Impl
        // 10. Allocator Proxy
        // 11. Swapper
        // 12. Earning Chain Gateway Impl
        // 13. Earning Chain Gateway Proxy
        // 14. Strategy Vault/4626

        transferHelper_earningChainAddress = address(new TransferHelper());

        uint256 deployerNonce_earningChain = vm.getNonce(address(this));
        accessManager_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tAccess Manager (Earning Chain) Predicted Address: %s", accessManager_earningChainAddress);

        deployerNonce_earningChain += 2; // Incrementing for Price Oracle implementation + proxy

        deployerNonce_earningChain++; // Incrementing for Asset Registry implementation
        assetRegistry_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tAsset Registry (Earning Chain) Predicted Address: %s", assetRegistry_earningChainAddress);

        deployerNonce_earningChain++; // Incrementing for Withdrawal Policy implementation
        withdrawalPolicy_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tWithdrawal Policy (Earning Chain) Predicted Address: %s", withdrawalPolicy_earningChainAddress);

        ccipAdapter_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tCCIP Adapter (Earning Chain) Predicted Address: %s", ccipAdapter_earningChainAddress);

        iouToken_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tIOU Token (Earning Chain) Predicted Address: %s", iouToken_earningChainAddress);

        deployerNonce_earningChain++; // Incrementing for IOU Token Manager implementation
        iouTokenManager_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tIOU Token Manager (Earning Chain) Predicted Address: %s", iouTokenManager_earningChainAddress);

        deployerNonce_earningChain++; // Incrementing for Allocator implementation
        allocator_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tAllocator (Earning Chain) Predicted Address: %s", allocator_earningChainAddress);

        swapper_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tSwapper (Earning Chain) Predicted Address: %s", swapper_earningChainAddress);

        deployerNonce_earningChain++; // Incrementing for Gateway implementation
        chainGateway_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tEarning Chain Gateway (Earning Chain) Predicted Address: %s", chainGateway_earningChainAddress);

        ghoStrategyVault_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tGHO Strategy Vault (Earning Chain) Predicted Address: %s", ghoStrategyVault_earningChainAddress);

        usdcStrategyVault_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log(
            "\tUSDC Strategy Vault (Earning Chain) Predicted Address: %s", usdcStrategyVault_earningChainAddress
        );

        // 1. Access Manager
        accessManager_earningChain = new AccessManager(admin);
        console.log("\tAccess Manager: %s", address(accessManager_earningChain));
        require(
            address(accessManager_earningChain) == accessManager_earningChainAddress,
            "Access Manager (Earning Chain) address mismatch"
        );

        // Deploy Price Oracle for Earning Chain (with mocked prices via vm.mockCall)
        priceOracle_earningChain = _deployPriceOracle(accessManager_earningChainAddress, 9_995e23);
        console.log("\tPrice Oracle (Earning Chain): %s", address(priceOracle_earningChain));
        if (_useMockedPriceOracleEarningChain()) {
            _mockAssetPrice(address(priceOracle_earningChain), address(GHO), MathLib.RAY);
            _mockAssetPrice(address(priceOracle_earningChain), address(USDC), MathLib.RAY);
            _mockValidatePriceForAll(address(priceOracle_earningChain));
        }

        // 2. Asset Registry
        address assetRegistry_earningChain_impl = address(new AssetRegistry());
        assetRegistry_earningChain = AssetRegistry(
            address(
                new TransparentUpgradeableProxy(
                    assetRegistry_earningChain_impl,
                    proxyAdmin,
                    abi.encodeCall(AssetRegistry.initialize, (accessManager_earningChainAddress))
                )
            )
        );
        console.log("\tAsset Registry: %s", address(assetRegistry_earningChain));
        require(
            address(assetRegistry_earningChain) == assetRegistry_earningChainAddress,
            "Asset Registry (Earning Chain) address mismatch"
        );

        // 3. Withdrawal Policy
        address withdrawalPolicy_earningChain_impl =
            address(new WithdrawalPolicy(assetRegistry_earningChainAddress, chainGateway_earningChainAddress));
        withdrawalPolicy_earningChain = WithdrawalPolicy(
            address(
                new TransparentUpgradeableProxy(
                    withdrawalPolicy_earningChain_impl,
                    proxyAdmin,
                    abi.encodeCall(WithdrawalPolicy.initialize, (accessManager_earningChainAddress, 0))
                )
            )
        );
        console.log("\tWithdrawal Policy (Earning Chain): %s", address(withdrawalPolicy_earningChain));
        require(
            address(withdrawalPolicy_earningChain) == withdrawalPolicy_earningChainAddress,
            "Withdrawal Policy (Earning Chain) address mismatch"
        );

        // 4. CCIP Router
        ccipAdapter_earningChain = new CcipAdapter(
            accessManager_earningChainAddress,
            chainGateway_earningChainAddress,
            address(mockCcipRouter),
            transferHelper_earningChainAddress
        );
        console.log("\tCCIP Adapter: %s", address(ccipAdapter_earningChain));
        require(
            address(ccipAdapter_earningChain) == ccipAdapter_earningChainAddress,
            "CCIP Adapter (Earning Chain) address mismatch"
        );

        // 5. IOU Token
        iouToken_earningChain = new IouToken(iouTokenManager_earningChainAddress);
        console.log("\tIOU Token (Earning Chain): %s", address(iouToken_earningChain));
        require(
            address(iouToken_earningChain) == iouToken_earningChainAddress, "IOU Token (Earning Chain) address mismatch"
        );

        // 6. IOU Token Manager
        address iouTokenManager_earningChain_impl = address(
            new IouTokenManager(
                iouToken_earningChainAddress,
                chainGateway_earningChainAddress,
                address(0),
                transferHelper_earningChainAddress,
                false
            )
        );
        iouTokenManager_earningChain = IouTokenManager(
            address(new TransparentUpgradeableProxy(iouTokenManager_earningChain_impl, proxyAdmin, ""))
        );
        console.log("\tIOU Token Manager (Earning Chain): %s", address(iouTokenManager_earningChain));
        require(
            address(iouTokenManager_earningChain) == iouTokenManager_earningChainAddress,
            "IOU Token Manager (Earning Chain) address mismatch"
        );

        // 7. Allocator
        address allocator_earningChain_impl = address(
            new Allocator(
                assetRegistry_earningChainAddress,
                chainGateway_earningChainAddress,
                chainGateway_earningChainAddress,
                address(priceOracle_earningChain),
                transferHelper_earningChainAddress,
                MAX_STRATEGIES_PER_ASSET
            )
        );
        allocator_earningChain = Allocator(
            address(
                new TransparentUpgradeableProxy(
                    allocator_earningChain_impl,
                    proxyAdmin,
                    abi.encodeCall(Allocator.initialize, (accessManager_earningChainAddress))
                )
            )
        );
        console.log("\tAllocator: %s", address(allocator_earningChain));
        require(
            address(allocator_earningChain) == allocator_earningChainAddress,
            "Allocator (Earning Chain) address mismatch"
        );

        // 8. Swapper
        swapper_earningChain = new Swapper(allocator_earningChainAddress);
        console.log("\tSwapper: %s", address(swapper_earningChain));
        require(
            address(swapper_earningChain) == swapper_earningChainAddress, "Swapper (Earning Chain) address mismatch"
        );

        // 9. Earning Chain Gateway
        address earningChainGateway_impl = address(
            new EarningChainGateway(
                ACCOUNTING_CHAIN_ID,
                allocator_earningChainAddress,
                address(priceOracle_earningChain),
                iouTokenManager_earningChainAddress,
                transferHelper_earningChainAddress,
                address(withdrawalPolicy_earningChain)
            )
        );
        earningChainGateway = EarningChainGateway(
            address(
                new TransparentUpgradeableProxy(
                    earningChainGateway_impl,
                    proxyAdmin,
                    abi.encodeCall(EarningChainGateway.initialize, (accessManager_earningChainAddress))
                )
            )
        );
        console.log("\tEarning Chain Gateway: %s", address(earningChainGateway));
        require(
            address(earningChainGateway) == chainGateway_earningChainAddress,
            "Earning Chain Gateway (Earning Chain) address mismatch"
        );

        // 10. Strategy Vault/4626
        ghoStrategyVault_earningChain = new TestErc4626(GHO);
        console.log("\tGHO Strategy Vault (Earning Chain): %s", address(ghoStrategyVault_earningChain));
        usdcStrategyVault_earningChain = new TestErc4626(USDC);
        console.log("\tUSDC Strategy Vault (Earning Chain): %s", address(usdcStrategyVault_earningChain));
        require(
            address(ghoStrategyVault_earningChain) == ghoStrategyVault_earningChainAddress,
            "GHO Strategy Vault (Earning Chain) address mismatch"
        );
        require(
            address(usdcStrategyVault_earningChain) == usdcStrategyVault_earningChainAddress,
            "USDC Strategy Vault (Earning Chain) address mismatch"
        );
    }

    function setUp() public virtual {
        // Warp to a reasonable timestamp to avoid underflow.
        vm.warp(block.timestamp + 1 days);

        _deployContracts();

        // Set up Access Manager roles on Accounting chain
        console.log("\nSetting up Access Manager roles on Accounting chain");
        _setUpAccountingChainAccessManager(accessManager_accountingChain);

        // Set up Access Manager roles on Earning chain
        console.log("\nSetting up Access Manager roles on Earning chain");
        _setUpEarningChainAccessManager(accessManager_earningChain);

        vm.startPrank(everyRoleAccount);

        console.log("\nInitializing Contracts");

        // Set up Accounting Chain Gateway (Accounting chain) // These should be done cross-wise cause it's destination
        // chainId
        accountingChainGateway.addBridgeAdapter(address(GHO), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain));
        accountingChainGateway.setDefaultBridgeAdapter(
            address(GHO), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain)
        );
        console.log(
            "\tAccountingChainGateway GHO adapter (Accounting Chain): %s",
            accountingChainGateway.getDefaultBridgeAdapter(address(GHO), EARNING_CHAIN_ID)
        );
        accountingChainGateway.addBridgeAdapter(address(USDC), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain));
        accountingChainGateway.setDefaultBridgeAdapter(
            address(USDC), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain)
        );
        console.log(
            "\tAccountingChainGateway USDC adapter (Accounting Chain): %s",
            accountingChainGateway.getDefaultBridgeAdapter(address(USDC), EARNING_CHAIN_ID)
        );
        accountingChainGateway.addBridgeAdapter(address(0), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain));
        accountingChainGateway.setDefaultBridgeAdapter(
            address(0), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain)
        );
        console.log(
            "\tAccountingChainGateway Message adapter (Accounting Chain): %s",
            accountingChainGateway.getDefaultBridgeAdapter(address(0), EARNING_CHAIN_ID)
        );

        // Set up Earning Chain Gateway (Earning chain)
        earningChainGateway.addBridgeAdapter(address(GHO), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        earningChainGateway.setDefaultBridgeAdapter(
            address(GHO), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain)
        );
        console.log(
            "\tEarningChainGatway GHO adapter (Earning Chain): %s",
            earningChainGateway.getDefaultBridgeAdapter(address(GHO), ACCOUNTING_CHAIN_ID)
        );
        earningChainGateway.addBridgeAdapter(address(USDC), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        earningChainGateway.setDefaultBridgeAdapter(
            address(USDC), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain)
        );
        console.log(
            "\tEarningChainGatway USDC adapter (Earning Chain): %s",
            earningChainGateway.getDefaultBridgeAdapter(address(USDC), ACCOUNTING_CHAIN_ID)
        );
        earningChainGateway.addBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        earningChainGateway.setDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        console.log(
            "\tEarningChainGatway Messages adapter (Earning Chain): %s",
            earningChainGateway.getDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID)
        );

        ccipAdapter_accountingChain.setChainSelector(EARNING_CHAIN_ID, EARNING_CHAIN_CCIP_SELECTOR);
        ccipAdapter_accountingChain.setDestinationChainAdapter(EARNING_CHAIN_ID, address(ccipAdapter_earningChain));

        ccipAdapter_earningChain.setChainSelector(ACCOUNTING_CHAIN_ID, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        ccipAdapter_earningChain.setDestinationChainAdapter(ACCOUNTING_CHAIN_ID, address(ccipAdapter_accountingChain));

        // Enable everything for assets
        IAssetRegistry.AssetConfig memory unrestrictedAssetConfig = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        // Set up Asset Registry on Accounting chain
        assetRegistry_accountingChain.setAssetConfig(address(GHO), unrestrictedAssetConfig);
        assetRegistry_accountingChain.setAssetConfig(address(USDC), unrestrictedAssetConfig);
        // Set up Asset Registry on Earning chain
        assetRegistry_earningChain.setAssetConfig(address(GHO), unrestrictedAssetConfig);
        assetRegistry_earningChain.setAssetConfig(address(USDC), unrestrictedAssetConfig);

        // Set up Allocator on Accounting chain
        allocator_accountingChain.addStrategy(
            address(GHO), address(ghoStrategyVault_accountingChain), STRATEGY_MAX_SLIPPAGE_AMOUNT
        );
        allocator_accountingChain.addStrategy(
            address(USDC), address(usdcStrategyVault_accountingChain), STRATEGY_MAX_SLIPPAGE_AMOUNT
        );
        allocator_accountingChain.setDefaultStrategy(address(GHO), address(ghoStrategyVault_accountingChain));
        allocator_accountingChain.setDefaultStrategy(address(USDC), address(usdcStrategyVault_accountingChain));

        // Set up Allocator on Earning chain
        allocator_earningChain.addStrategy(
            address(GHO), address(ghoStrategyVault_earningChain), STRATEGY_MAX_SLIPPAGE_AMOUNT
        );
        allocator_earningChain.addStrategy(
            address(USDC), address(usdcStrategyVault_earningChain), STRATEGY_MAX_SLIPPAGE_AMOUNT
        );
        allocator_earningChain.setDefaultStrategy(address(GHO), address(ghoStrategyVault_earningChain));
        allocator_earningChain.setDefaultStrategy(address(USDC), address(usdcStrategyVault_earningChain));

        // Configure the FundsHandler to track the earning chain balance via the oracle
        fundsHandler.addEarningChain(EARNING_CHAIN_ID);

        // Set up EarningChainStateProvider -> MockBundleFeed -> Chainlink adapter -> ChainBalanceOracle.
        // Use a harness so snapshots encode the simulated Earning Chain id in single-EVM E2E tests.
        earningChainStateProvider = IEarningChainStateProvider(
            address(new EarningChainStateProviderHarness(address(earningChainGateway), EARNING_CHAIN_ID))
        );
        mockBundleFeed = new MockBundleFeed();
        chainBalanceOracleAdapter = new ChainlinkChainBalanceOracleAdapter(
            EARNING_CHAIN_ID, address(mockBundleFeed), CHAIN_BALANCE_ORACLE_HEARTBEAT_SECONDS
        );
        _publishChainBalanceSnapshotToBundleFeed(0, block.timestamp, block.number);
        chainBalanceOracle.setChainBalanceOracleAdapter(EARNING_CHAIN_ID, address(chainBalanceOracleAdapter));

        vm.stopPrank();
    }

    function _setUpAccountingChainAccessManager(AccessManager accessManager) internal {
        vm.startPrank(admin);

        // AccessManager setup below is intentionally minimal for tests (single executor, zero delays).
        // A separate test suite is used to validate the AccessManager roles and permissions.

        // ----- Set up Guardian -----
        accessManager.grantRole(GUARDIAN_ROLE, everyRoleAccount, 0);

        // ----- Set up Appender -----
        //_setUpRole(accessManager, APPENDER_ROLE, everyRoleAccount, 1 days * 7);
        _setUpRole(accessManager, APPENDER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain), _toSelectorArray(IAllocator.addStrategy.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(assetRegistry_accountingChain),
            _toSelectorArray(
                IAssetRegistry.setAssetConfig.selector,
                IAssetRegistry.distrustAsset.selector,
                IAssetRegistry.trustAsset.selector
            ),
            APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(accountingChainGateway), _toSelectorArray(IChainGateway.addBridgeAdapter.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(ccipAdapter_accountingChain),
            _toSelectorArray(
                IBridgeAdapter.setDestinationChainAdapter.selector, ICcipBridgeAdapter.setChainSelector.selector
            ),
            APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(chainBalanceOracle),
            _toSelectorArray(ChainBalanceOracle.setChainBalanceOracleAdapter.selector),
            APPENDER_ROLE
        );

        // ----- Set up Remover -----
        _setUpRole(accessManager, REMOVER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain), _toSelectorArray(IAllocator.removeStrategy.selector), REMOVER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(accountingChainGateway), _toSelectorArray(IChainGateway.removeBridgeAdapter.selector), REMOVER_ROLE
        );

        // ----- Set up Rescuer -----
        _setUpRole(accessManager, RESCUER_ROLE, everyRoleAccount, 0);
        bytes4[] memory rescueSelectorAsArray =
            _toSelectorArray(IRescuableToken.rescueTokens.selector, IRescuableNative.rescueNative.selector);
        accessManager.setTargetFunctionRole(address(vault), rescueSelectorAsArray, RESCUER_ROLE);
        accessManager.setTargetFunctionRole(address(fundsHandler), rescueSelectorAsArray, RESCUER_ROLE);
        accessManager.setTargetFunctionRole(address(accountingChainGateway), rescueSelectorAsArray, RESCUER_ROLE);

        // ----- Set up Profit Taker -----
        _setUpRole(accessManager, PROFIT_TAKER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(vault), _toSelectorArray(IBasedBoostedVault.claimSurplusInterest.selector), PROFIT_TAKER_ROLE
        );

        // ----- Set up Operator -----
        _setUpRole(accessManager, OPERATOR_ROLE, everyRoleAccount, 0);

        // For Allocator on Accounting chain
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain),
            _toSelectorArray(IAllocator.rebalance.selector, IAllocator.setDefaultStrategy.selector),
            OPERATOR_ROLE
        );

        // For Accounting Chain Gateway
        accessManager.setTargetFunctionRole(
            address(accountingChainGateway),
            _toSelectorArray(IChainGateway.setDefaultBridgeAdapter.selector),
            OPERATOR_ROLE
        );

        // For BasedBoostedVault
        accessManager.setTargetFunctionRole(
            address(vault),
            _toSelectorArray(
                IBasedBoostedVault.setUserRate.selector,
                IBasedBoostedVault.setSubVaultRate.selector,
                IBasedBoostedVault.setDefaultSubVault.selector
            ),
            OPERATOR_ROLE
        );

        // For FundsHandler
        accessManager.setTargetFunctionRole(
            address(fundsHandler),
            _toSelectorArray(IFundsHandler.pushFundsToChain.selector, FundsHandler.addEarningChain.selector),
            OPERATOR_ROLE
        );

        vm.stopPrank();
    }

    function _setUpEarningChainAccessManager(AccessManager accessManager) internal {
        vm.startPrank(admin);

        // AccessManager setup below is intentionally minimal for tests (single executor, zero delays).

        // ----- Set up Guardian -----
        accessManager.grantRole(GUARDIAN_ROLE, everyRoleAccount, 0);

        // ----- Set up Appender -----
        //_setUpRole(accessManager, APPENDER_ROLE, everyRoleAccount, 1 days * 7);
        _setUpRole(accessManager, APPENDER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain), _toSelectorArray(IAllocator.addStrategy.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(assetRegistry_earningChain),
            _toSelectorArray(
                IAssetRegistry.setAssetConfig.selector,
                IAssetRegistry.distrustAsset.selector,
                IAssetRegistry.trustAsset.selector
            ),
            APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(earningChainGateway), _toSelectorArray(IChainGateway.addBridgeAdapter.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(ccipAdapter_earningChain),
            _toSelectorArray(
                IBridgeAdapter.setDestinationChainAdapter.selector, ICcipBridgeAdapter.setChainSelector.selector
            ),
            APPENDER_ROLE
        );

        // ----- Set up Remover -----
        _setUpRole(accessManager, REMOVER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain), _toSelectorArray(IAllocator.removeStrategy.selector), REMOVER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(earningChainGateway), _toSelectorArray(IChainGateway.removeBridgeAdapter.selector), REMOVER_ROLE
        );

        // ----- Set up Rescuer -----
        _setUpRole(accessManager, RESCUER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(earningChainGateway),
            _toSelectorArray(IRescuableToken.rescueTokens.selector, IRescuableNative.rescueNative.selector),
            RESCUER_ROLE
        );

        // ----- Set up Operator -----
        _setUpRole(accessManager, OPERATOR_ROLE, everyRoleAccount, 0);

        // For Allocator on Earning chain
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain),
            _toSelectorArray(IAllocator.rebalance.selector, IAllocator.setDefaultStrategy.selector),
            OPERATOR_ROLE
        );

        // For Earning Chain Gateway
        accessManager.setTargetFunctionRole(
            address(earningChainGateway),
            _toSelectorArray(
                IChainGateway.setDefaultBridgeAdapter.selector, IEarningChainGateway.pushFundsToAccountingChain.selector
            ),
            OPERATOR_ROLE
        );

        vm.stopPrank();
    }

    function _setUpRole(AccessManager accessManager, uint64 roleId, address account, uint32 executionDelay) internal {
        accessManager.grantRole(roleId, account, executionDelay);
        accessManager.setRoleGuardian(roleId, GUARDIAN_ROLE);
    }

    function _publishChainBalanceFromEarningChainStateProvider() internal {
        bytes memory stateBytes = earningChainStateProvider.getState();
        mockBundleFeed.publishState(stateBytes);
    }

    function _publishChainBalanceSnapshotToBundleFeed(
        uint256 balanceRay,
        uint256 sourceChainTimestamp,
        uint256 sourceChainBlockNumber
    ) internal {
        bytes memory stateBytes = abi.encode(
            IEarningChainStateProvider.State({
                version: EARNING_CHAIN_STATE_VERSION,
                data: abi.encode(
                    EarningChainStateProvider_V1.BalanceSnapshot({
                        balanceRay: balanceRay,
                        timestamp: sourceChainTimestamp,
                        blockNumber: sourceChainBlockNumber,
                        chainId: EARNING_CHAIN_ID
                    })
                )
            })
        );
        mockBundleFeed.publishState(stateBytes);
    }

    function _mockChainBalance(
        uint256 chainId,
        uint256 balanceRay,
        uint256 lastUpdateTimestamp,
        uint256 sourceChainTimestamp,
        bool isStale
    ) internal {
        _mockChainBalance(chainId, balanceRay, lastUpdateTimestamp, sourceChainTimestamp, block.number, isStale);
    }

    function _mockChainBalance(
        uint256 chainId,
        uint256 balanceRay,
        uint256 lastUpdateTimestamp,
        uint256 sourceChainTimestamp,
        uint256 sourceChainBlockNumber,
        bool isStale
    ) internal {
        require(chainId == EARNING_CHAIN_ID, "Unsupported chain id");
        _publishChainBalanceSnapshotToBundleFeed(balanceRay, sourceChainTimestamp, sourceChainBlockNumber);
        if (isStale) {
            mockBundleFeed.setLatestBundleTimestamp(
                block.timestamp - CHAIN_BALANCE_ORACLE_HEARTBEAT_SECONDS - CHAIN_BALANCE_ORACLE_PUBLISH_BUFFER_SECONDS
            );
        } else {
            mockBundleFeed.setLatestBundleTimestamp(lastUpdateTimestamp);
        }
    }

    /// @dev Deploys a PriceOracle with TransparentUpgradeableProxy (overrides TestWithHelpers to use proxyAdmin)
    function _deployPriceOracle(address accessManager, uint256 minValidPriceRay)
        internal
        override
        returns (PriceOracle)
    {
        address priceOracleImpl = address(new PriceOracle(minValidPriceRay));
        return PriceOracle(
            address(
                new TransparentUpgradeableProxy(
                    priceOracleImpl, proxyAdmin, abi.encodeCall(PriceOracle.initialize, (accessManager))
                )
            )
        );
    }

    function _deployChainBalanceOracle(address accessManager) internal returns (ChainBalanceOracle) {
        address chainBalanceOracleImpl = address(new ChainBalanceOracle());
        return ChainBalanceOracle(
            address(
                new TransparentUpgradeableProxy(
                    chainBalanceOracleImpl, proxyAdmin, abi.encodeCall(ChainBalanceOracle.initialize, (accessManager))
                )
            )
        );
    }
}
