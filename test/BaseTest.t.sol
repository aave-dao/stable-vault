// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ExtendedAccessManager} from "../src/common/ExtendedAccessManager.sol";

import {AssetRegistry} from "../src/common/AssetRegistry.sol";
import {IouToken} from "../src/common/IouToken.sol";
import {IouTokenManager} from "../src/common/IouTokenManager.sol";
import {IAllocator} from "../src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "../src/interfaces/IAssetRegistry.sol";
import {IBasedBoostedVault} from "../src/interfaces/IBasedBoostedVault.sol";
import {IBridgeAdapter} from "../src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "../src/interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "../src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../src/interfaces/IEarningChainGateway.sol";
import {IFundsHandler} from "../src/interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "../src/interfaces/IIouTokenManager.sol";
import {IRescuableAssets} from "../src/interfaces/IRescuableAssets.sol";
import {AccountingChainGateway} from "./../src/accounting/AccountingChainGateway.sol";
import {FundsHandler} from "./../src/accounting/FundsHandler.sol";
import {CcipAdapter} from "./../src/bridging/CcipAdapter.sol";
import {Allocator} from "./../src/common/Allocator.sol";
import {Swapper} from "./../src/common/Swapper.sol";
import {EarningChainGateway} from "./../src/earning/EarningChainGateway.sol";
import {AssetLib} from "./../src/libraries/AssetLib.sol";
import {MathLib} from "./../src/libraries/MathLib.sol";
import {ExtendedBasedBoostedVault} from "./mocks/ExtendedBasedBoostedVault.sol";
import {MockCCIPRouter} from "./mocks/MockRouter.sol";
import {TestErc20} from "./mocks/TestErc20.sol";
import {TestErc4626} from "./mocks/TestErc4626.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "test/helpers/TypeHelpers.sol";

contract BaseTest is Test {
    using MathLib for uint256;
    using AssetLib for uint256;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

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

    uint256 constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    uint64 public constant ACCOUNTING_CHAIN_ID = 1;
    uint64 public constant ACCOUNTING_CHAIN_CCIP_SELECTOR = 10;
    uint64 public constant EARNING_CHAIN_ID = 2;
    uint64 public constant EARNING_CHAIN_CCIP_SELECTOR = 20;

    // Currencies
    TestErc20 GHO = new TestErc20(18);
    TestErc20 USDC = new TestErc20(6);

    // Accounting Chain: BBV, FH, Swapper, Allocator, Accounting Chain Gateway, CCIP Adapter, CCIP Router, Strategy
    // Vault/4626
    address accessManager_accountingChainAddress;
    address vault_accountingChainAddress;
    address iouToken_accountingChainAddress;
    address iouTokenManager_accountingChainAddress;
    address assetRegistry_accountingChainAddress;
    address fundsHandler_accountingChainAddress;
    address allocator_accountingChainAddress;
    address swapper_accountingChainAddress;
    address chainGateway_accountingChainAddress;
    address ccipAdapter_accountingChainAddress;
    address ghoStrategyVault_accountingChainAddress;
    address usdcStrategyVault_accountingChainAddress;
    ExtendedAccessManager accessManager_accountingChain;
    ExtendedBasedBoostedVault vault;
    IouToken iouToken_accountingChain;
    IouTokenManager iouTokenManager_accountingChain;
    AssetRegistry assetRegistry_accountingChain;
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
    address iouToken_earningChainAddress;
    address iouTokenManager_earningChainAddress;
    address ccipAdapter_earningChainAddress;
    address chainGateway_earningChainAddress;
    address allocator_earningChainAddress;
    address swapper_earningChainAddress;
    address ghoStrategyVault_earningChainAddress;
    address usdcStrategyVault_earningChainAddress;
    ExtendedAccessManager accessManager_earningChain;
    AssetRegistry assetRegistry_earningChain;
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
        address fh,
        address assetRegistry
    ) internal virtual returns (ExtendedBasedBoostedVault) {
        return new ExtendedBasedBoostedVault(
            accessManager, maxPerSecondRate, defaultSubVaultPerSecondRate, iouTokenManager, fh, assetRegistry
        );
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

        console.log("\nAccounting Chain:");
        // ---- Accounting Chain ----
        // Accounting Chain: BBV, FH, Swapper, Allocator, Accounting Chain Gateway, CCIP Adapter, CCIP Router, Strategy,
        // Asset Registry Vault/4626

        // Deployment order:
        // 1. Access Manager
        // 2. Asset Registry
        // 3. IOU Token
        // 4. IOU Token Manager
        // 5. Based Boosted Vault
        // 6. Allocator
        // 7. Funds Handler
        // 8. Accounting Chain Gateway
        // 9. Swapper
        // 10. CCIP Adapter
        // 11. Strategy Vault/4626

        // Pre compute addresses for contracts that are with circular dependencies
        uint256 deployerNonce_accountingChain = vm.getNonce(address(this));
        console.log("\tDeployer Nonce (Accounting Chain): %s", deployerNonce_accountingChain);
        accessManager_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tAccess Manager (Accounting Chain) Predicted Address: %s", accessManager_accountingChainAddress);
        assetRegistry_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tAsset Registry (Accounting Chain) Predicted Address: %s", assetRegistry_accountingChainAddress);
        iouToken_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tIOU Token (Accounting Chain) Predicted Address: %s", iouToken_accountingChainAddress);
        iouTokenManager_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log(
            "\tIOU Token Manager (Accounting Chain) Predicted Address: %s", iouTokenManager_accountingChainAddress
        );
        vault_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tVault (Accounting Chain) Predicted Address: %s", vault_accountingChainAddress);
        allocator_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tAllocator (Accounting Chain) Predicted Address: %s", allocator_accountingChainAddress);
        fundsHandler_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tFunds Handler (Accounting Chain) Predicted Address: %s", fundsHandler_accountingChainAddress);
        chainGateway_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log(
            "\tAccounting Chain Gateway (Accounting Chain) Predicted Address: %s", chainGateway_accountingChainAddress
        );
        swapper_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tSwapper (Accounting Chain) Predicted Address: %s", swapper_accountingChainAddress);
        ccipAdapter_accountingChainAddress = vm.computeCreateAddress(address(this), deployerNonce_accountingChain++);
        console.log("\tCCIP Adapter (Accounting Chain) Predicted Address: %s", ccipAdapter_accountingChainAddress);

        // 1. Access Manager
        accessManager_accountingChain = new ExtendedAccessManager(admin);
        console.log("\tAccess Manager: %s", address(accessManager_accountingChain));
        require(
            address(accessManager_accountingChain) == accessManager_accountingChainAddress,
            "Access Manager (Accounting Chain) address mismatch"
        );

        // 2. Asset Registry
        assetRegistry_accountingChain = new AssetRegistry(address(accessManager_accountingChain));
        console.log("\tAsset Registry: %s", address(assetRegistry_accountingChain));
        require(
            address(assetRegistry_accountingChain) == assetRegistry_accountingChainAddress,
            "Asset Registry (Accounting Chain) address mismatch"
        );

        // 3. IOU Token
        iouToken_accountingChain = new IouToken(iouTokenManager_accountingChainAddress);
        console.log("\tIOU Token (Accounting Chain): %s", iouToken_accountingChainAddress);
        require(
            address(iouToken_accountingChain) == iouToken_accountingChainAddress,
            "IOU Token (Accounting Chain) address mismatch"
        );

        // 4. IOU Token Manager
        iouTokenManager_accountingChain = new IouTokenManager(
            accessManager_accountingChainAddress,
            iouToken_accountingChainAddress,
            chainGateway_accountingChainAddress,
            true
        );
        console.log("\tIOU Token Manager (Accounting Chain): %s", address(iouTokenManager_accountingChain));
        require(
            address(iouTokenManager_accountingChain) == iouTokenManager_accountingChainAddress,
            "IOU Token Manager (Accounting Chain) address mismatch"
        );

        // 5. Based Boosted Vault
        vault = _deployBasedBoostedVault(
            accessManager_accountingChainAddress,
            DEFAULT_MAX_PER_SECOND_RATE,
            initialBasePerSecondRate,
            iouTokenManager_accountingChainAddress,
            fundsHandler_accountingChainAddress,
            assetRegistry_accountingChainAddress
        );
        console.log("\tVault: %s", vault_accountingChainAddress);
        require(address(vault) == vault_accountingChainAddress, "Vault (Accounting Chain) address mismatch");

        // 6. Allocator
        allocator_accountingChain = new Allocator(
            accessManager_accountingChainAddress,
            assetRegistry_accountingChainAddress,
            fundsHandler_accountingChainAddress,
            fundsHandler_accountingChainAddress
        );
        console.log("\tAllocator: %s", allocator_accountingChainAddress);
        require(
            address(allocator_accountingChain) == allocator_accountingChainAddress,
            "Allocator (Accounting Chain) address mismatch"
        );

        // 7. Funds Handler
        fundsHandler = new FundsHandler(
            accessManager_accountingChainAddress,
            vault_accountingChainAddress,
            chainGateway_accountingChainAddress,
            allocator_accountingChainAddress
        );
        console.log("\tFunds Handler: %s", address(fundsHandler));
        require(
            address(fundsHandler) == fundsHandler_accountingChainAddress,
            "Funds Handler (Accounting Chain) address mismatch"
        );

        // 8. Accounting Chain Gateway
        accountingChainGateway = new AccountingChainGateway(
            accessManager_accountingChainAddress,
            fundsHandler_accountingChainAddress,
            iouTokenManager_accountingChainAddress
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
            accessManager_accountingChainAddress, chainGateway_accountingChainAddress, address(mockCcipRouter)
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
        // 2. Asset Registry
        // 3. CCIP Router
        // 4. IOU Token
        // 5. IOU Token Manager
        // 6. Allocator
        // 7. Swapper
        // 8. Earning Chain Gateway
        // 9. Strategy Vault/4626

        uint256 deployerNonce_earningChain = vm.getNonce(address(this));
        accessManager_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tAccess Manager (Earning Chain) Predicted Address: %s", accessManager_earningChainAddress);
        assetRegistry_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tAsset Registry (Earning Chain) Predicted Address: %s", assetRegistry_earningChainAddress);
        ccipAdapter_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tCCIP Adapter (Earning Chain) Predicted Address: %s", ccipAdapter_earningChainAddress);
        iouToken_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tIOU Token (Earning Chain) Predicted Address: %s", iouToken_earningChainAddress);
        iouTokenManager_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tIOU Token Manager (Earning Chain) Predicted Address: %s", iouTokenManager_earningChainAddress);
        allocator_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tAllocator (Earning Chain) Predicted Address: %s", allocator_earningChainAddress);
        swapper_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tSwapper (Earning Chain) Predicted Address: %s", swapper_earningChainAddress);
        chainGateway_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tEarning Chain Gateway (Earning Chain) Predicted Address: %s", chainGateway_earningChainAddress);
        ghoStrategyVault_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log("\tGHO Strategy Vault (Earning Chain) Predicted Address: %s", ghoStrategyVault_earningChainAddress);
        usdcStrategyVault_earningChainAddress = vm.computeCreateAddress(address(this), deployerNonce_earningChain++);
        console.log(
            "\tUSDC Strategy Vault (Earning Chain) Predicted Address: %s", usdcStrategyVault_earningChainAddress
        );

        // 1. Access Manager
        accessManager_earningChain = new ExtendedAccessManager(admin);
        console.log("\tAccess Manager: %s", address(accessManager_earningChain));
        require(
            address(accessManager_earningChain) == accessManager_earningChainAddress,
            "Access Manager (Earning Chain) address mismatch"
        );

        // 2. Asset Registry
        assetRegistry_earningChain = new AssetRegistry(address(accessManager_earningChain));
        console.log("\tAsset Registry: %s", address(assetRegistry_earningChain));
        require(
            address(assetRegistry_earningChain) == assetRegistry_earningChainAddress,
            "Asset Registry (Earning Chain) address mismatch"
        );

        // 3. CCIP Router
        ccipAdapter_earningChain = new CcipAdapter(
            accessManager_earningChainAddress, chainGateway_earningChainAddress, address(mockCcipRouter)
        );
        console.log("\tCCIP Adapter: %s", address(ccipAdapter_earningChain));
        require(
            address(ccipAdapter_earningChain) == ccipAdapter_earningChainAddress,
            "CCIP Adapter (Earning Chain) address mismatch"
        );

        // 4. IOU Token
        iouToken_earningChain = new IouToken(iouToken_earningChainAddress);
        console.log("\tIOU Token (Earning Chain): %s", address(iouToken_earningChain));
        require(
            address(iouToken_earningChain) == iouToken_earningChainAddress, "IOU Token (Earning Chain) address mismatch"
        );

        // 5. IOU Token Manager
        iouTokenManager_earningChain = new IouTokenManager(
            accessManager_earningChainAddress, iouToken_earningChainAddress, chainGateway_earningChainAddress, false
        );
        console.log("\tIOU Token Manager (Earning Chain): %s", address(iouTokenManager_earningChain));
        require(
            address(iouTokenManager_earningChain) == iouTokenManager_earningChainAddress,
            "IOU Token Manager (Earning Chain) address mismatch"
        );

        // 6. Allocator
        allocator_earningChain = new Allocator(
            accessManager_earningChainAddress,
            assetRegistry_earningChainAddress,
            allocator_earningChainAddress,
            allocator_earningChainAddress
        );
        console.log("\tAllocator: %s", address(allocator_earningChain));
        require(
            address(allocator_earningChain) == allocator_earningChainAddress,
            "Allocator (Earning Chain) address mismatch"
        );

        // 7. Swapper
        swapper_earningChain = new Swapper(allocator_earningChainAddress);
        console.log("\tSwapper: %s", address(swapper_earningChain));
        require(
            address(swapper_earningChain) == swapper_earningChainAddress, "Swapper (Earning Chain) address mismatch"
        );

        // 8. Earning Chain Gateway
        earningChainGateway = new EarningChainGateway(
            accessManager_earningChainAddress,
            ACCOUNTING_CHAIN_ID,
            iouTokenManager_earningChainAddress,
            allocator_earningChainAddress
        );
        console.log("\tEarning Chain Gateway: %s", address(earningChainGateway));
        require(
            address(earningChainGateway) == chainGateway_earningChainAddress,
            "Earning Chain Gateway (Earning Chain) address mismatch"
        );

        // 9. Strategy Vault/4626
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

        // ccipAdapter_accountingChain.setFeeToken(address(USDC));
        // ccipAdapter_earningChain.setFeeToken(address(USDC));
        ccipAdapter_accountingChain.setChainSelector(EARNING_CHAIN_ID, EARNING_CHAIN_CCIP_SELECTOR);
        ccipAdapter_accountingChain.setDestinationChainAdapter(EARNING_CHAIN_ID, address(ccipAdapter_earningChain));

        ccipAdapter_earningChain.setChainSelector(ACCOUNTING_CHAIN_ID, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        ccipAdapter_earningChain.setDestinationChainAdapter(ACCOUNTING_CHAIN_ID, address(ccipAdapter_accountingChain));

        // Set up Allocator on Accounting chain
        allocator_accountingChain.addVault(address(GHO), address(ghoStrategyVault_accountingChain));
        allocator_accountingChain.addVault(address(USDC), address(usdcStrategyVault_accountingChain));
        allocator_accountingChain.setDefaultVault(address(GHO), address(ghoStrategyVault_accountingChain));
        allocator_accountingChain.setDefaultVault(address(USDC), address(usdcStrategyVault_accountingChain));

        // Set up Allocator on Earning chain
        allocator_earningChain.addVault(address(GHO), address(ghoStrategyVault_earningChain));
        allocator_earningChain.addVault(address(USDC), address(usdcStrategyVault_earningChain));
        allocator_earningChain.setDefaultVault(address(GHO), address(ghoStrategyVault_earningChain));
        allocator_earningChain.setDefaultVault(address(USDC), address(usdcStrategyVault_earningChain));

        // Enable everything for assets
        IAssetRegistry.AssetConfig memory unrestrictedAssetConfig = IAssetRegistry.AssetConfig({
            depositIntoBBVAllowed: true,
            withdrawFromBBVAllowed: true,
            depositIntoAllocatorAllowed: true,
            withdrawFromAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        // Set up Asset Registry on Accounting chain
        assetRegistry_accountingChain.setAssetConfig(address(GHO), unrestrictedAssetConfig);
        assetRegistry_accountingChain.setAssetConfig(address(USDC), unrestrictedAssetConfig);
        // Set up Asset Registry on Earning chain
        assetRegistry_earningChain.setAssetConfig(address(GHO), unrestrictedAssetConfig);
        assetRegistry_earningChain.setAssetConfig(address(USDC), unrestrictedAssetConfig);

        vm.stopPrank();
    }

    function _setUpAccountingChainAccessManager(ExtendedAccessManager accessManager) internal {
        vm.startPrank(admin);

        // TODO: set up RoleAdmin role which can grant and revoke roles
        // TODO: MasterAdmin needs to set grantDelay on all role

        // ----- Set up Guardian -----
        accessManager.grantRole(GUARDIAN_ROLE, everyRoleAccount, 0);

        // ----- Set up Upgrade Proxy Admin -----
        //_setUpRole(accessManager, UPGRADE_PROXY_ADMIN_ROLE, everyRoleAccount, 1 days * 15);
        _setUpRole(accessManager, UPGRADE_PROXY_ADMIN_ROLE, everyRoleAccount, 0);
        bytes4[] memory upgradeSelectors = _toSelectorArray(ITransparentUpgradeableProxy.upgradeToAndCall.selector);
        // TODO(upgrade): add all upgradabale targets here
        address[] memory upgradeTargets = new address[](0);
        for (uint256 i = 0; i < upgradeTargets.length; i++) {
            accessManager.setTargetFunctionRole(upgradeTargets[i], upgradeSelectors, UPGRADE_PROXY_ADMIN_ROLE);
        }

        // ----- Set up Appender -----
        //_setUpRole(accessManager, APPENDER_ROLE, everyRoleAccount, 1 days * 7);
        _setUpRole(accessManager, APPENDER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain), _toSelectorArray(IAllocator.addVault.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(assetRegistry_accountingChain),
            _toSelectorArray(IAssetRegistry.setAssetConfig.selector),
            APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(accountingChainGateway), _toSelectorArray(IChainGateway.addBridgeAdapter.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(ccipAdapter_accountingChain),
            _toSelectorArray(
                IBridgeAdapter.setDestinationChainAdapter.selector,
                ICcipBridgeAdapter.setChainSelector.selector,
                ICcipBridgeAdapter.setFeeToken.selector
            ),
            APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(iouTokenManager_accountingChain),
            _toSelectorArray(
                IIouTokenManager.setAllowedMinter.selector,
                IIouTokenManager.setAllowedBurner.selector,
                IIouTokenManager.setAllowedReleaser.selector
            ),
            APPENDER_ROLE
        );

        // ----- Set up Remover -----
        _setUpRole(accessManager, REMOVER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain), _toSelectorArray(IAllocator.removeVault.selector), REMOVER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(accountingChainGateway), _toSelectorArray(IChainGateway.removeBridgeAdapter.selector), REMOVER_ROLE
        );

        // ----- Set up Rescuer -----
        _setUpRole(accessManager, RESCUER_ROLE, everyRoleAccount, 0);
        bytes4[] memory rescueSelectorAsArray = _toSelectorArray(IRescuableAssets.rescueTokens.selector);
        accessManager.setTargetFunctionRole(address(vault), rescueSelectorAsArray, RESCUER_ROLE);
        accessManager.setTargetFunctionRole(address(fundsHandler), rescueSelectorAsArray, RESCUER_ROLE);
        accessManager.setTargetFunctionRole(address(accountingChainGateway), rescueSelectorAsArray, RESCUER_ROLE);

        // ----- Set up Profit Taker -----
        _setUpRole(accessManager, PROFIT_TAKER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(vault), _toSelectorArray(IBasedBoostedVault.claimFees.selector), PROFIT_TAKER_ROLE
        );

        // ----- Set up Operator -----
        _setUpRole(accessManager, OPERATOR_ROLE, everyRoleAccount, 0);

        // For Allocator on Accounting chain
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain),
            _toSelectorArray(
                IAllocator.deallocate.selector,
                IAllocator.depositIdleFunds.selector,
                IAllocator.rebalance.selector,
                IAllocator.reallocate.selector,
                IAllocator.setDefaultVault.selector
            ),
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
            address(fundsHandler), _toSelectorArray(IFundsHandler.pushFundsToChain.selector), OPERATOR_ROLE
        );

        vm.stopPrank();
    }

    function _setUpEarningChainAccessManager(ExtendedAccessManager accessManager) internal {
        vm.startPrank(admin);

        // TODO: set up RoleAdmin role which can grant and revoke roles
        // TODO: MasterAdmin needs to set grantDelay on all roles
        // TODO: creater Pauser role

        // ----- Set up Guardian -----
        accessManager.grantRole(GUARDIAN_ROLE, everyRoleAccount, 0);

        // ----- Set up Upgrade Proxy Admin -----
        //_setUpRole(accessManager, UPGRADE_PROXY_ADMIN_ROLE, everyRoleAccount, 1 days * 15);
        _setUpRole(accessManager, UPGRADE_PROXY_ADMIN_ROLE, everyRoleAccount, 0);
        bytes4[] memory upgradeSelectors = _toSelectorArray(ITransparentUpgradeableProxy.upgradeToAndCall.selector);
        // TODO(upgrade): add all upgradabale targets here
        address[] memory upgradeTargets = new address[](0);
        for (uint256 i = 0; i < upgradeTargets.length; i++) {
            accessManager.setTargetFunctionRole(upgradeTargets[i], upgradeSelectors, UPGRADE_PROXY_ADMIN_ROLE);
        }

        // ----- Set up Appender -----
        //_setUpRole(accessManager, APPENDER_ROLE, everyRoleAccount, 1 days * 7);
        _setUpRole(accessManager, APPENDER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain), _toSelectorArray(IAllocator.addVault.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(assetRegistry_earningChain), _toSelectorArray(IAssetRegistry.setAssetConfig.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(earningChainGateway), _toSelectorArray(IChainGateway.addBridgeAdapter.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(ccipAdapter_earningChain),
            _toSelectorArray(
                IBridgeAdapter.setDestinationChainAdapter.selector,
                ICcipBridgeAdapter.setChainSelector.selector,
                ICcipBridgeAdapter.setFeeToken.selector
            ),
            APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(iouTokenManager_earningChain),
            _toSelectorArray(
                IIouTokenManager.setAllowedMinter.selector,
                IIouTokenManager.setAllowedBurner.selector,
                IIouTokenManager.setAllowedReleaser.selector
            ),
            APPENDER_ROLE
        );

        // ----- Set up Remover -----
        _setUpRole(accessManager, REMOVER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain), _toSelectorArray(IAllocator.removeVault.selector), REMOVER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(earningChainGateway), _toSelectorArray(IChainGateway.removeBridgeAdapter.selector), REMOVER_ROLE
        );

        // ----- Set up Rescuer -----
        _setUpRole(accessManager, RESCUER_ROLE, everyRoleAccount, 0);
        accessManager.setTargetFunctionRole(
            address(earningChainGateway), _toSelectorArray(IRescuableAssets.rescueTokens.selector), RESCUER_ROLE
        );

        // ----- Set up Operator -----
        _setUpRole(accessManager, OPERATOR_ROLE, everyRoleAccount, 0);

        // For Allocator on Earning chain
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain),
            _toSelectorArray(
                IAllocator.deallocate.selector,
                IAllocator.depositIdleFunds.selector,
                IAllocator.rebalance.selector,
                IAllocator.reallocate.selector,
                IAllocator.setDefaultVault.selector
            ),
            OPERATOR_ROLE
        );

        // For Earning Chain Gateway
        accessManager.setTargetFunctionRole(
            address(earningChainGateway),
            _toSelectorArray(
                IChainGateway.setDefaultBridgeAdapter.selector,
                IEarningChainGateway.sendBalanceUpdate.selector,
                IEarningChainGateway.exit.selector
            ),
            OPERATOR_ROLE
        );

        vm.stopPrank();
    }

    function _setUpRole(ExtendedAccessManager accessManager, uint64 roleId, address account, uint32 executionDelay)
        internal
    {
        accessManager.grantRole(roleId, account, executionDelay);
        accessManager.setRoleGuardian(roleId, GUARDIAN_ROLE);
    }
}
