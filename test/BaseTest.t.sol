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
import {IChainGateway} from "../src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../src/interfaces/IEarningChainGateway.sol";
import {IFundsHandler} from "../src/interfaces/IFundsHandler.sol";
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
    address manager = makeAddr("MANAGER");
    address guardian = makeAddr("GUARDIAN");
    address upgradeProxyAdmin = makeAddr("UPGRADE_PROXY_ADMIN");
    address appender = makeAddr("APPENDER");
    address remover = makeAddr("REMOVER");
    address rescuer = makeAddr("RESCUER");
    address profitTaker = makeAddr("PROFIT_TAKER");
    address operator = makeAddr("OPERATOR");

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
        _setUpAccountingChainAccessManager(accessManager_accountingChain);

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
        _setUpEarningChainAccessManager(accessManager_earningChain);

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

    function _setUpAccountingChainAccessManager(ExtendedAccessManager accessManager) internal {
        vm.startPrank(admin);

        // TODO: set up RoleAdmin role which can grant and revoke roles
        // TODO: MasterAdmin needs to set grantDelay on all roles
        // TODO: creater Pauser role

        // ----- Set up Guardian -----
        accessManager.grantRole(GUARDIAN_ROLE, guardian, 0);

        // ----- Set up Upgrade Proxy Admin -----
        _setUpRole(accessManager, UPGRADE_PROXY_ADMIN_ROLE, upgradeProxyAdmin, 1 days * 15);
        bytes4[] memory upgradeSelectors = _toSelectorArray(ITransparentUpgradeableProxy.upgradeToAndCall.selector);
        // TODO(upgrade): add all upgradabale targets here
        address[] memory upgradeTargets = new address[](0);
        for (uint256 i = 0; i < upgradeTargets.length; i++) {
            accessManager.setTargetFunctionRole(upgradeTargets[i], upgradeSelectors, UPGRADE_PROXY_ADMIN_ROLE);
        }

        // ----- Set up Appender -----
        _setUpRole(accessManager, APPENDER_ROLE, appender, 1 days * 7);
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

        // ----- Set up Remover -----
        _setUpRole(accessManager, REMOVER_ROLE, remover, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain), _toSelectorArray(IAllocator.removeVault.selector), REMOVER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(accountingChainGateway), _toSelectorArray(IChainGateway.removeBridgeAdapter.selector), REMOVER_ROLE
        );

        // ----- Set up Rescuer -----
        _setUpRole(accessManager, RESCUER_ROLE, rescuer, 0);
        bytes4[] memory rescueSelectorAsArray = _toSelectorArray(IRescuableAssets.rescueTokens.selector);
        accessManager.setTargetFunctionRole(address(vault), rescueSelectorAsArray, RESCUER_ROLE);
        accessManager.setTargetFunctionRole(address(fundsHandler), rescueSelectorAsArray, RESCUER_ROLE);
        accessManager.setTargetFunctionRole(address(accountingChainGateway), rescueSelectorAsArray, RESCUER_ROLE);

        // ----- Set up Profit Taker -----
        _setUpRole(accessManager, PROFIT_TAKER_ROLE, profitTaker, 0);
        accessManager.setTargetFunctionRole(
            address(vault), _toSelectorArray(IBasedBoostedVault.claimFees.selector), PROFIT_TAKER_ROLE
        );

        // ----- Set up Operator -----
        _setUpRole(accessManager, OPERATOR_ROLE, operator, 0);

        // For Allocator on Accounting chain
        accessManager.setTargetFunctionRole(
            address(allocator_accountingChain),
            _toSelectorArray(
                IAllocator.deallocate.selector,
                IAllocator.depositIdleFunds.selector,
                IAllocator.rebalance.selector,
                IAllocator.reallocate.selector
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
        accessManager.grantRole(GUARDIAN_ROLE, guardian, 0);

        // ----- Set up Upgrade Proxy Admin -----
        _setUpRole(accessManager, UPGRADE_PROXY_ADMIN_ROLE, upgradeProxyAdmin, 1 days * 15);
        bytes4[] memory upgradeSelectors = _toSelectorArray(ITransparentUpgradeableProxy.upgradeToAndCall.selector);
        // TODO(upgrade): add all upgradabale targets here
        address[] memory upgradeTargets = new address[](0);
        for (uint256 i = 0; i < upgradeTargets.length; i++) {
            accessManager.setTargetFunctionRole(upgradeTargets[i], upgradeSelectors, UPGRADE_PROXY_ADMIN_ROLE);
        }

        // ----- Set up Appender -----
        _setUpRole(accessManager, APPENDER_ROLE, appender, 1 days * 7);
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain), _toSelectorArray(IAllocator.addVault.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(assetRegistry_earningChain), _toSelectorArray(IAssetRegistry.setAssetConfig.selector), APPENDER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(earningChainGateway), _toSelectorArray(IChainGateway.addBridgeAdapter.selector), APPENDER_ROLE
        );

        // ----- Set up Remover -----
        _setUpRole(accessManager, REMOVER_ROLE, remover, 0);
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain), _toSelectorArray(IAllocator.removeVault.selector), REMOVER_ROLE
        );
        accessManager.setTargetFunctionRole(
            address(earningChainGateway), _toSelectorArray(IChainGateway.removeBridgeAdapter.selector), REMOVER_ROLE
        );

        // ----- Set up Rescuer -----
        _setUpRole(accessManager, RESCUER_ROLE, rescuer, 0);
        accessManager.setTargetFunctionRole(
            address(earningChainGateway), _toSelectorArray(IRescuableAssets.rescueTokens.selector), RESCUER_ROLE
        );

        // ----- Set up Operator -----
        _setUpRole(accessManager, OPERATOR_ROLE, operator, 0);

        // For Allocator on Earning chain
        accessManager.setTargetFunctionRole(
            address(allocator_earningChain),
            _toSelectorArray(
                IAllocator.deallocate.selector,
                IAllocator.depositIdleFunds.selector,
                IAllocator.rebalance.selector,
                IAllocator.reallocate.selector
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

    function _setUpRole(ExtendedAccessManager accessManager, uint64 roleId, address account, uint32 executionDelay) internal {
        accessManager.grantRole(roleId, account, executionDelay);
        accessManager.setRoleGuardian(roleId, GUARDIAN_ROLE);
    }
}
