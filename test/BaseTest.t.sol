// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ExtendedAccessManager} from "../src/common/ExtendedAccessManager.sol";

import {AssetRegistry} from "../src/common/AssetRegistry.sol";
import {IouToken} from "../src/common/IouToken.sol";
import {IouTokenManager} from "../src/common/IouTokenManager.sol";
import {IAllocator} from "../src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "../src/interfaces/IAssetRegistry.sol";
import {IBasedBoostedVault} from "../src/interfaces/IBasedBoostedVault.sol";
import {IChainGateway} from "../src/interfaces/IChainGateway.sol";
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
import {MockAccessManager} from "./mocks/MockAccessManager.sol";
import {MockCCIPRouter} from "./mocks/MockRouter.sol";
import {TestErc20} from "./mocks/TestErc20.sol";
import {TestErc4626} from "./mocks/TestErc4626.sol";

contract BaseTest is Test {
    using MathLib for uint256;
    using AssetLib for uint256;

    address admin = makeAddr("ADMIN");
    address manager = makeAddr("MANAGER");
    address guardian = makeAddr("GUARDIAN");
    address upgradeProxyAdmin = makeAddr("UPGRADE_PROXY_ADMIN");
    address appender = makeAddr("APPENDER");
    address remover = makeAddr("REMOVER");
    address rescuer = makeAddr("RESCUER");
    address profitTaker = makeAddr("PROFIT_TAKER");
    address operator = makeAddr("OPERATOR");

    // ADMIN_ROLE = 0
    uint64 internal constant GUARDIAN_ROLE = 1;
    uint64 internal constant UPGRADE_PROXY_ADMIN_ROLE = 2;
    uint64 internal constant APPENDER_ROLE = 3;
    uint64 internal constant REMOVER_ROLE = 4;
    uint64 internal constant RESCUER_ROLE = 5;
    uint64 internal constant PROFIT_TAKER_ROLE = 6;
    uint64 internal constant OPERATOR_ROLE = 7;

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
        address adminParam,
        uint256 maxPerSecondRate,
        uint256 defaultSubVaultPerSecondRate,
        address iouToken,
        address assetRegistry
    ) internal virtual returns (ExtendedBasedBoostedVault) {
        return new ExtendedBasedBoostedVault(
            adminParam, maxPerSecondRate, defaultSubVaultPerSecondRate, iouToken, assetRegistry
        );
    }

    function _deployContracts() internal {
        console.log("\n-------------------");
        console.log("\nDeploying contracts");
        console.log("\tManager: %s", manager);
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
        // Accounting Chain: BBV, FH, Swapper, Allocator, Accounting Chain Gateway, CCIP Adapter, CCIP Router, Strategy,
        // Asset Registry Vault/4626
        accessManager_accountingChain = new ExtendedAccessManager(admin);
        console.log("\tAccess Manager: %s", address(accessManager_accountingChain));
        assetRegistry_accountingChain = new AssetRegistry(address(this));
        // Enable everything for assets
        IAssetRegistry.AssetConfig memory unrestrictedAssetConfig = IAssetRegistry.AssetConfig({
            depositIntoBBVAllowed: true,
            withdrawFromBBVAllowed: true,
            depositIntoAllocatorAllowed: true,
            withdrawFromAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        assetRegistry_accountingChain.setAssetConfig(address(GHO), unrestrictedAssetConfig);
        assetRegistry_accountingChain.setAssetConfig(address(USDC), unrestrictedAssetConfig);
        iouToken_accountingChain = new IouToken(address(this));
        console.log("\tIOU Token (Accounting Chain): %s", address(iouToken_accountingChain));
        iouTokenManager_accountingChain = new IouTokenManager(address(iouToken_accountingChain), true);
        console.log("\tIOU Token Manager (Accounting Chain): %s", address(iouTokenManager_accountingChain));
        iouToken_accountingChain.transferOwnership(address(iouTokenManager_accountingChain));
        vault = _deployBasedBoostedVault(
            admin,
            DEFAULT_MAX_PER_SECOND_RATE,
            initialBasePerSecondRate,
            address(iouTokenManager_accountingChain),
            address(assetRegistry_accountingChain)
        );
        console.log("\tVault: %s", address(vault));
        allocator_accountingChain = new Allocator(manager, admin, address(assetRegistry_accountingChain));
        console.log("\tAllocator: %s", address(allocator_accountingChain));

        uint256 deployerNonce = vm.getNonce(address(this));
        address accountingChainGatewayAddress = vm.computeCreateAddress(address(this), deployerNonce + 1);
        console.log("\tAccounting Chain Gateway Predicted Address: %s", accountingChainGatewayAddress);
        vm.prank(admin);
        iouTokenManager_accountingChain.setChainGateway(accountingChainGatewayAddress);

        fundsHandler = new FundsHandler(
            manager, address(vault), accountingChainGatewayAddress, address(allocator_accountingChain)
        );
        console.log("\tFunds Handler: %s", address(fundsHandler));
        accountingChainGateway = new AccountingChainGateway(
            address(accessManager_accountingChain), address(fundsHandler), address(iouTokenManager_accountingChain)
        );
        console.log("\tAccounting Chain Gateway: %s", address(accountingChainGateway));
        swapper_accountingChain = new Swapper(address(allocator_accountingChain));
        console.log("\tSwapper: %s", address(swapper_accountingChain));
        ccipAdapter_accountingChain = new CcipAdapter(admin, address(mockCcipRouter));
        console.log("\tCCIP Adapter: %s", address(ccipAdapter_accountingChain));

        ghoStrategyVault_accountingChain = new TestErc4626(GHO);
        console.log("\tGHO Strategy Vault (Accounting Chain): %s", address(ghoStrategyVault_accountingChain));
        usdcStrategyVault_accountingChain = new TestErc4626(USDC);
        console.log("\tUSDC Strategy Vault (Accounting Chain): %s", address(usdcStrategyVault_accountingChain));

        // /////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Earning Chain: Access Manager, Earning Chain Gateway, CCIP Adapter, CCIP Router, Swapper, Allocator, Strategy
        // Vault/4626, Asset Registry
        console.log("\nEarning Chain:");
        accessManager_earningChain = new ExtendedAccessManager(admin);
        console.log("\tAccess Manager: %s", address(accessManager_earningChain));
        assetRegistry_earningChain = new AssetRegistry(address(this));
        // Enable everything for assets
        assetRegistry_earningChain.setAssetConfig(address(GHO), unrestrictedAssetConfig);
        assetRegistry_earningChain.setAssetConfig(address(USDC), unrestrictedAssetConfig);
        ccipAdapter_earningChain = new CcipAdapter(admin, address(mockCcipRouter));
        iouToken_earningChain = new IouToken(address(this));
        console.log("\tIOU Token (Earning Chain): %s", address(iouToken_earningChain));
        iouTokenManager_earningChain = new IouTokenManager(address(iouToken_earningChain), false);
        console.log("\tIOU Token Manager (Earning Chain): %s", address(iouTokenManager_earningChain));
        iouToken_earningChain.transferOwnership(address(iouTokenManager_earningChain));
        allocator_earningChain = new Allocator(manager, admin, address(assetRegistry_earningChain));
        console.log("\tAllocator: %s", address(allocator_earningChain));
        swapper_earningChain = new Swapper(address(allocator_earningChain));
        console.log("\tSwapper: %s", address(swapper_earningChain));
        earningChainGateway = new EarningChainGateway(
            address(accessManager_earningChain),
            ACCOUNTING_CHAIN_ID,
            address(iouTokenManager_earningChain),
            address(allocator_earningChain)
        );
        console.log("\tEarning Chain Gateway: %s", address(earningChainGateway));
        vm.prank(admin);
        iouTokenManager_earningChain.setChainGateway(address(earningChainGateway));

        ghoStrategyVault_earningChain = new TestErc4626(GHO);
        console.log("\tGHO Strategy Vault (Earning Chain): %s", address(ghoStrategyVault_earningChain));
        usdcStrategyVault_earningChain = new TestErc4626(USDC);
        console.log("\tUSDC Strategy Vault (Earning Chain): %s", address(usdcStrategyVault_earningChain));
    }

    function setUp() public virtual {
        _deployContracts();
        // _prepareTokens();

        // ------------------------------------------------
        // ADMIN ACTIONS
        // ------------------------------------------------

        vm.startPrank(admin);

        // Set up BBV
        vault.setFundsHandler(address(fundsHandler));
        vault.setManager(manager);

        // Set up Allocators on Accounting chain
        allocator_accountingChain.setDepositor(address(fundsHandler), true);
        allocator_accountingChain.setWithdrawer(address(fundsHandler), true);
        allocator_accountingChain.setDepositor(address(accountingChainGateway), true);
        allocator_accountingChain.setWithdrawer(address(accountingChainGateway), true);

        // Set up Allocators on Earning chain
        allocator_earningChain.setDepositor(address(earningChainGateway), true);
        allocator_earningChain.setWithdrawer(address(earningChainGateway), true);

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

        // Set up Access Manager roles on Accounting chain
        _setUpAccountingChainAccessManager();

        // Set up Earning Chain Gateway (Earning chain)
        vm.prank(appender);
        earningChainGateway.addBridgeAdapter(address(GHO), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        vm.prank(operator);
        earningChainGateway.setDefaultBridgeAdapter(
            address(GHO), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain)
        );
        console.log(
            "\tEarningChainGatway GHO adapter (Earning Chain): %s",
            earningChainGateway.getDefaultBridgeAdapter(address(GHO), ACCOUNTING_CHAIN_ID)
        );
        vm.prank(appender);
        earningChainGateway.addBridgeAdapter(address(USDC), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        vm.prank(operator);
        earningChainGateway.setDefaultBridgeAdapter(
            address(USDC), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain)
        );
        console.log(
            "\tEarningChainGatway USDC adapter (Earning Chain): %s",
            earningChainGateway.getDefaultBridgeAdapter(address(USDC), ACCOUNTING_CHAIN_ID)
        );
        vm.prank(appender);
        earningChainGateway.addBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        vm.prank(operator);
        earningChainGateway.setDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        console.log(
            "\tEarningChainGatway Messages adapter (Earning Chain): %s",
            earningChainGateway.getDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID)
        );

        ccipAdapter_accountingChain.setGateway(address(accountingChainGateway));
        ccipAdapter_earningChain.setGateway(address(earningChainGateway));
        // ccipAdapter_accountingChain.setFeeToken(address(USDC));
        // ccipAdapter_earningChain.setFeeToken(address(USDC));
        ccipAdapter_accountingChain.setChainSelector(EARNING_CHAIN_ID, EARNING_CHAIN_CCIP_SELECTOR);
        ccipAdapter_earningChain.setChainSelector(ACCOUNTING_CHAIN_ID, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        ccipAdapter_accountingChain.setDestinationChainAdapter(EARNING_CHAIN_ID, address(ccipAdapter_earningChain));
        ccipAdapter_earningChain.setDestinationChainAdapter(ACCOUNTING_CHAIN_ID, address(ccipAdapter_accountingChain));

        // Set up Allocator on Accounting chain
        allocator_accountingChain.addVault(address(GHO), address(ghoStrategyVault_accountingChain));
        allocator_accountingChain.addVault(address(USDC), address(usdcStrategyVault_accountingChain));

        // Set up Allocator on Earning chain
        allocator_earningChain.addVault(address(GHO), address(ghoStrategyVault_earningChain));
        allocator_earningChain.addVault(address(USDC), address(usdcStrategyVault_earningChain));

        // Set up Access Manager roles on Earning chain
        accessManager_earningChain.setUpGuardian(guardian);

        address[] memory upgradeProxyTargets_earningChain = new address[](0);
        accessManager_earningChain.setUpUpgradeProxyRole(upgradeProxyAdmin, upgradeProxyTargets_earningChain);
        accessManager_earningChain.setUpAppenderRole(
            appender, address(allocator_earningChain), address(assetRegistry_earningChain), address(earningChainGateway)
        );
        accessManager_earningChain.setUpRemoverRole(
            remover, address(allocator_earningChain), address(earningChainGateway)
        );
        accessManager_earningChain.setUpRescuerRole(
            rescuer, address(vault), address(fundsHandler), address(earningChainGateway)
        );
        accessManager_earningChain.setUpProfitTakerRole(profitTaker, address(vault));
        accessManager_earningChain.setUpEarningChainOperatorRole(
            operator, address(earningChainGateway), address(allocator_earningChain)
        );

        vm.stopPrank();

        // ------------------------------------------------
        // MANAGER ACTIONS
        // ------------------------------------------------

        vm.startPrank(manager);
        // Set default vaults for assets
        allocator_accountingChain.setDefaultVault(address(GHO), address(ghoStrategyVault_accountingChain));
        allocator_accountingChain.setDefaultVault(address(USDC), address(usdcStrategyVault_accountingChain));
        allocator_earningChain.setDefaultVault(address(GHO), address(ghoStrategyVault_earningChain));
        allocator_earningChain.setDefaultVault(address(USDC), address(usdcStrategyVault_earningChain));

        vm.stopPrank();

        console.log("\n-------------------");
    }

    function _setUpAccountingChainAccessManager() internal {
        vm.startPrank(admin);
        // TODO: add targets of upgradable contracts for upgrade proxy

        // Set Up Guardian
        address[] memory upgradeProxyTargets_accountingChain = new address[](0);
        accessManager_accountingChain.setUpGuardian(guardian);
        accessManager_accountingChain.setUpUpgradeProxyRole(upgradeProxyAdmin, upgradeProxyTargets_accountingChain);
        accessManager_accountingChain.setUpAppenderRole(
            appender,
            address(allocator_accountingChain),
            address(assetRegistry_accountingChain),
            address(accountingChainGateway)
        );
        accessManager_accountingChain.setUpRemoverRole(
            remover, address(allocator_accountingChain), address(accountingChainGateway)
        );
        accessManager_accountingChain.setUpRescuerRole(
            rescuer, address(vault), address(fundsHandler), address(accountingChainGateway)
        );
        accessManager_accountingChain.setUpProfitTakerRole(profitTaker, address(vault));
        accessManager_accountingChain.setUpAccountingChainOperatorRole(
            operator,
            address(vault),
            address(fundsHandler),
            address(accountingChainGateway),
            address(allocator_accountingChain)
        );
        vm.stopPrank();
    }

    function _setUpAccessManager(ExtendedAccessManager accessManager) internal {
        vm.startPrank(admin);

        // TODO: set up RoleAdmin role which can grant and revoke roles
        // TODO: MasterAdmin needs to set grantDelay on all roles
        // TODO: creater Pauser role

        uint256 executionDelay;

        // ----- Set up Guardian -----
        accessManager.grantRole(GUARDIAN_ROLE, guardian, 0);

        // ----- Set up Upgrade Proxy Admin -----
        executionDelay = 1 days * 15;
        accessManager.grantRole(UPGRADE_PROXY_ADMIN_ROLE, upgradeProxyAdmin, executionDelay);
        accessManager.setRoleGuardian(UPGRADE_PROXY_ADMIN_ROLE, GUARDIAN_ROLE);
        // TODO(upgrade): set upgrade selector for all relavent contracts
        bytes4 selector = 0x00000000;
        bytes4[] memory upgradeSelectors = new bytes4[](1);
        upgradeSelectors[0] = selector;
        // TODO(upgrade): add all upgradabale targets here
        address[] memory upgradeTargets = new address[](0);
        for (uint256 i = 0; i < upgradeTargets.length; i++) {
            accessManager.setTargetFunctionRole(upgradeTargets[i], upgradeSelectors, UPGRADE_PROXY_ADMIN_ROLE);
        }

        // ----- Set up Appender -----
        executionDelay = 1 days * 7;
        accessManager.grantRole(APPENDER_ROLE, appender, executionDelay);
        accessManager.setRoleGuardian(APPENDER_ROLE, GUARDIAN_ROLE);
        bytes4[] memory addSelectorsAllocator = new bytes4[](1);
        addSelectorsAllocator[0] = IAllocator.addVault.selector;
        accessManager.setTargetFunctionRole(address(allocator_accountingChain), addSelectorsAllocator, APPENDER_ROLE);
        bytes4[] memory addSelectorsAssetRegistry = new bytes4[](1);
        addSelectorsAssetRegistry[0] = IAssetRegistry.setAssetConfig.selector;
        accessManager.setTargetFunctionRole(
            address(assetRegistry_accountingChain), addSelectorsAssetRegistry, APPENDER_ROLE
        );
        bytes4[] memory addSelectorsGateway = new bytes4[](1);
        addSelectorsGateway[0] = IChainGateway.addBridgeAdapter.selector;
        accessManager.setTargetFunctionRole(address(accountingChainGateway), addSelectorsGateway, APPENDER_ROLE);

        // ----- Set up Remover -----
        executionDelay = 0;
        accessManager.grantRole(REMOVER_ROLE, remover, executionDelay);
        accessManager.setRoleGuardian(REMOVER_ROLE, GUARDIAN_ROLE);
        bytes4[] memory removeSelectorsAllocator = new bytes4[](1);
        removeSelectorsAllocator[0] = IAllocator.removeVault.selector;
        accessManager.setTargetFunctionRole(address(allocator_accountingChain), removeSelectorsAllocator, REMOVER_ROLE);
        bytes4[] memory removeSelectorsGateway = new bytes4[](1);
        removeSelectorsGateway[0] = IChainGateway.removeBridgeAdapter.selector;
        accessManager.setTargetFunctionRole(address(accountingChainGateway), removeSelectorsGateway, REMOVER_ROLE);

        // ----- Set up Rescuer -----
        executionDelay = 0;
        accessManager.grantRole(RESCUER_ROLE, rescuer, executionDelay);
        accessManager.setRoleGuardian(RESCUER_ROLE, GUARDIAN_ROLE);
        bytes4[] memory rescueSelectors = new bytes4[](1);
        rescueSelectors[0] = IRescuableAssets.rescueTokens.selector;
        address[] memory rescueTargets = new address[](3);
        rescueTargets[0] = address(vault);
        rescueTargets[1] = address(fundsHandler);
        rescueTargets[2] = address(accountingChainGateway);
        for (uint256 i = 0; i < rescueTargets.length; i++) {
            accessManager.setTargetFunctionRole(rescueTargets[i], rescueSelectors, RESCUER_ROLE);
        }

        // ----- Set up Profit Taker -----
        executionDelay = 0;
        accessManager.grantRole(PROFIT_TAKER_ROLE, profitTaker, executionDelay);
        accessManager.setRoleGuardian(PROFIT_TAKER_ROLE, GUARDIAN_ROLE);
        bytes4[] memory claimFeesSelectors = new bytes4[](1);
        claimFeesSelectors[0] = IBasedBoostedVault.claimFees.selector;
        accessManager.setTargetFunctionRole(address(vault), claimFeesSelectors, PROFIT_TAKER_ROLE);

        // ----- Set up Operator -----
        executionDelay = 0;
        accessManager.grantRole(OPERATOR_ROLE, operator, executionDelay);
        accessManager.setRoleGuardian(OPERATOR_ROLE, GUARDIAN_ROLE);

        // For Allocator on Accounting chain
        bytes4[] memory operatorSelectorsAllocator = new bytes4[](4);
        operatorSelectorsAllocator[0] = IAllocator.deallocate.selector;
        operatorSelectorsAllocator[1] = IAllocator.depositIdleFunds.selector;
        operatorSelectorsAllocator[2] = IAllocator.rebalance.selector;
        operatorSelectorsAllocator[3] = IAllocator.reallocate.selector;
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain), operatorSelectorsAllocator, OPERATOR_ROLE
        );

        // For Accounting Chain Gateway TODO: finish from here
        bytes4[] memory operatorSelectorsGateway = new bytes4[](1);
        operatorSelectorsGateway[0] = IChainGateway.setDefaultBridgeAdapter.selector;
        accessManager.setTargetFunctionRole(address(accountingChainGateway), operatorSelectorsGateway, OPERATOR_ROLE);

        vm.stopPrank();
    }
}
