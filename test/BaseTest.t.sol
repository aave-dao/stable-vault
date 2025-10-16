// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ExtendedBasedBoostedVault} from "./mocks/ExtendedBasedBoostedVault.sol";
import {TestErc4626} from "./mocks/TestErc4626.sol";
import {TestErc20} from "./mocks/TestErc20.sol";
import {MathLib} from "./../src/libraries/MathLib.sol";
import {AssetLib} from "./../src/libraries/AssetLib.sol";
import {FundsHandler} from "./../src/accounting/FundsHandler.sol";
import {AccountingChainGateway} from "./../src/accounting/AccountingChainGateway.sol";
import {Allocator} from "./../src/common/Allocator.sol";
import {Swapper} from "./../src/common/Swapper.sol";
import {CcipAdapter} from "./../src/bridging/CcipAdapter.sol";
import {MockCCIPRouter} from "./mocks/MockRouter.sol";
import {EarningChainGateway} from "./../src/earning/EarningChainGateway.sol";

contract BaseTest is Test {
    using MathLib for uint256;
    using AssetLib for uint256;

    address admin = makeAddr("ADMIN");
    address manager = makeAddr("MANAGER");
    uint256 initialBasePerSecondRate = MathLib.RAY; // 1 RAY

    uint64 public constant ACCOUNTING_CHAIN_ID = 1;
    uint64 public constant ACCOUNTING_CHAIN_CCIP_SELECTOR = 10;
    uint64 public constant EARNING_CHAIN_ID = 2;
    uint64 public constant EARNING_CHAIN_CCIP_SELECTOR = 20;

    // Currencies
    TestErc20 GHO = new TestErc20(18);
    TestErc20 USDC = new TestErc20(6);

    // Accounting Chain: BBV, FH, Swapper, Allocator, Accounting Chain Gateway, CCIP Adapter, CCIP Router, Strategy Vault/4626
    ExtendedBasedBoostedVault vault;
    FundsHandler fundsHandler;
    Allocator allocator_accountingChain;
    Swapper swapper_accountingChain;
    AccountingChainGateway accountingChainGateway;
    CcipAdapter ccipAdapter_accountingChain;
    TestErc4626 ghoStrategyVault_accountingChain;
    TestErc4626 usdcStrategyVault_accountingChain;

    // Earning Chain: Earning Chain Gateway, CCIP Adapter, CCIP Router, Swapper, Allocator, Strategy Vault/4626
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

    function _deployContracts() internal {
        console.log("\n-------------------");
        console.log("\nDeploying contracts");
        console.log("\tManager: %s", manager);
        console.log("\tAdmin: %s", admin);
        console.log("\tInitial Base Per Second Rate: %s", initialBasePerSecondRate);
        console.log("\tAccounting Chain ID: %s", ACCOUNTING_CHAIN_ID);
        console.log("\tEarning Chain ID: %s", EARNING_CHAIN_ID);

        console.log("\nAccounting Chain:");
        // Accounting Chain: BBV, FH, Swapper, Allocator, Accounting Chain Gateway, CCIP Adapter, CCIP Router, Strategy Vault/4626
        vault = new ExtendedBasedBoostedVault(admin, initialBasePerSecondRate);
        console.log("\tVault: %s", address(vault));
        allocator_accountingChain = new Allocator(manager, admin);
        console.log("\tAllocator: %s", address(allocator_accountingChain));

        uint256 deployerNonce = vm.getNonce(address(this));
        address accountingChainGatewayAddress = vm.computeCreateAddress(address(this), deployerNonce + 1);
        console.log("\tAccounting Chain Gateway Predicted Address: %s", accountingChainGatewayAddress);

        fundsHandler = new FundsHandler(
            manager, address(vault), accountingChainGatewayAddress, address(allocator_accountingChain)
        );
        console.log("\tFunds Handler: %s", address(fundsHandler));
        accountingChainGateway = new AccountingChainGateway(admin, address(fundsHandler));
        console.log("\tAccounting Chain Gateway: %s", address(accountingChainGateway));
        swapper_accountingChain = new Swapper(address(allocator_accountingChain));
        console.log("\tSwapper: %s", address(swapper_accountingChain));
        ccipAdapter_accountingChain = new CcipAdapter();
        console.log("\tCCIP Adapter: %s", address(ccipAdapter_accountingChain));

        ghoStrategyVault_accountingChain = new TestErc4626(GHO);
        console.log("\tGHO Strategy Vault (Accounting Chain): %s", address(ghoStrategyVault_accountingChain));
        usdcStrategyVault_accountingChain = new TestErc4626(USDC);
        console.log("\tUSDC Strategy Vault (Accounting Chain): %s", address(usdcStrategyVault_accountingChain));

        ///////////////////////////////////////////////////////////////////////////////////////////////////////////////
        // Earning Chain: Earning Chain Gateway, CCIP Adapter, CCIP Router, Swapper, Allocator, Strategy Vault/4626
        console.log("\nEarning Chain:");
        ccipAdapter_earningChain = new CcipAdapter();
        console.log("\tCCIP Adapter: %s", address(ccipAdapter_earningChain));
        earningChainGateway = new EarningChainGateway(admin, ACCOUNTING_CHAIN_ID);
        console.log("\tEarning Chain Gateway: %s", address(earningChainGateway));
        allocator_earningChain = new Allocator(manager, admin);
        console.log("\tAllocator: %s", address(allocator_earningChain));
        swapper_earningChain = new Swapper(address(allocator_earningChain));
        console.log("\tSwapper: %s", address(swapper_earningChain));

        ghoStrategyVault_earningChain = new TestErc4626(GHO);
        console.log("\tGHO Strategy Vault (Earning Chain): %s", address(ghoStrategyVault_earningChain));
        usdcStrategyVault_earningChain = new TestErc4626(USDC);
        console.log("\tUSDC Strategy Vault (Earning Chain): %s", address(usdcStrategyVault_earningChain));

        // ccip mock
        mockCcipRouter = new MockCCIPRouter();
        console.log("\tMock CCIP Router: %s", address(mockCcipRouter));

        mockCcipRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        mockCcipRouter.setSourceChainSelector(ACCOUNTING_CHAIN_CCIP_SELECTOR, EARNING_CHAIN_CCIP_SELECTOR);
    }

    function setUp() public virtual {
        _deployContracts();
        // _prepareTokens();

        // ------------------------------------------------
        //                  ADMIN ACTIONS
        // ------------------------------------------------

        vm.startPrank(admin);

        // Set up BBV
        vault.updateAssetSupport(address(GHO), true);
        vault.updateAssetSupport(address(USDC), true);
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

        // Set up Accounting Chain Gateway (Accounting chain) // These should be done cross-wise cause it's destination chainId
        accountingChainGateway.setBridgeAdapter(address(GHO), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain));
        console.log(
            "\tAccountingChainGateway GHO adapter (Accounting Chain): %s",
            accountingChainGateway.getBridgeAdapter(address(GHO), EARNING_CHAIN_ID)
        );
        accountingChainGateway.setBridgeAdapter(address(USDC), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain));
        console.log(
            "\tAccountingChainGateway USDC adapter (Accounting Chain): %s",
            accountingChainGateway.getBridgeAdapter(address(USDC), EARNING_CHAIN_ID)
        );
        accountingChainGateway.setBridgeAdapter(address(0), EARNING_CHAIN_ID, address(ccipAdapter_accountingChain));
        console.log(
            "\tAccountingChainGateway Message adapter (Accounting Chain): %s",
            accountingChainGateway.getBridgeAdapter(address(0), EARNING_CHAIN_ID)
        );

        // Set up Earning Chain Gateway (Earning chain)
        earningChainGateway.setManager(manager);
        earningChainGateway.setAllocator(address(allocator_earningChain));
        earningChainGateway.setBridgeAdapter(address(GHO), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        console.log(
            "\tEarningChainGatway GHO adapter (Earning Chain): %s",
            earningChainGateway.getBridgeAdapter(address(GHO), ACCOUNTING_CHAIN_ID)
        );
        earningChainGateway.setBridgeAdapter(address(USDC), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        console.log(
            "\tEarningChainGatway USDC adapter (Earning Chain): %s",
            earningChainGateway.getBridgeAdapter(address(USDC), ACCOUNTING_CHAIN_ID)
        );
        earningChainGateway.setBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(ccipAdapter_earningChain));
        console.log(
            "\tEarningChainGatway Messages adapter (Earning Chain): %s",
            earningChainGateway.getBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID)
        );

        ccipAdapter_accountingChain.setGateway(address(accountingChainGateway));
        ccipAdapter_earningChain.setGateway(address(earningChainGateway));
        ccipAdapter_accountingChain.setCcipRouter(address(mockCcipRouter));
        ccipAdapter_earningChain.setCcipRouter(address(mockCcipRouter));
        // ccipAdapter_accountingChain.setFeeToken(address(USDC));
        // ccipAdapter_earningChain.setFeeToken(address(USDC));
        ccipAdapter_accountingChain.setChainSelector(EARNING_CHAIN_ID, EARNING_CHAIN_CCIP_SELECTOR);
        ccipAdapter_earningChain.setChainSelector(ACCOUNTING_CHAIN_ID, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        ccipAdapter_accountingChain.setChainReceiver(EARNING_CHAIN_ID, address(ccipAdapter_earningChain));
        ccipAdapter_earningChain.setChainReceiver(ACCOUNTING_CHAIN_ID, address(ccipAdapter_accountingChain));
        vm.stopPrank();

        // ------------------------------------------------
        //                  MANAGER ACTIONS
        // ------------------------------------------------

        vm.startPrank(manager);
        // Set up strategies on Accounting chain
        allocator_accountingChain.setVault(address(GHO), address(ghoStrategyVault_accountingChain));
        allocator_accountingChain.setVault(address(USDC), address(usdcStrategyVault_accountingChain));

        // Set up strategies on Earning chain
        allocator_earningChain.setVault(address(GHO), address(ghoStrategyVault_earningChain));
        allocator_earningChain.setVault(address(USDC), address(usdcStrategyVault_earningChain));

        vm.stopPrank();

        console.log("\n-------------------");
    }
}
