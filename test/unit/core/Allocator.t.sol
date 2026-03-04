// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Allocator} from "src/core/Allocator.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockErc4626Strategy} from "test/mocks/MockErc4626Strategy.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";
import {TestErc4626} from "test/mocks/TestErc4626.sol";
import {TestErc4626WithSlippage} from "test/mocks/TestErc4626WithSlippage.sol";

contract AllocatorTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMockErc20;

    uint8 constant STRATEGY_MAX_SLIPPAGE_AMOUNT = 10;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    // Represents the FH on Accounting Chain, Earning Chain Gateway on Earning Chain
    address depositor = makeAddr("DEPOSITOR");
    // Represents the FH on Accounting Chain, Earning Chain Gateway on Earning Chain
    address withdrawer = makeAddr("WITHDRAWER");

    uint8 constant MAX_STRATEGIES_PER_ASSET = 15;

    MockAssetRegistry internal _mockAssetRegistry;
    MockAccessManager internal _mockAccessManager;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    IMockErc20 internal _mockUnsupportedAsset;
    TestErc4626 internal _defaultUsdtStrategy;
    TestErc4626 internal _extraUsdtStrategy;
    TestErc4626 internal _defaultGhoStrategy;
    TestErc4626 internal _extraGhoStrategy;
    MockSwapper internal _mockSwapper;
    PriceOracle internal _priceOracle;
    MockTransferHelper internal _mockTransferHelper;

    Allocator internal _allocator;

    function _deployAllocator(
        MockAccessManager mockAccessManager,
        address assetRegistry,
        address priceOracle,
        address transferHelper,
        uint8 maxStrategiesPerAsset
    ) internal returns (Allocator) {
        address allocatorImpl = address(
            new Allocator(assetRegistry, depositor, withdrawer, priceOracle, transferHelper, maxStrategiesPerAsset)
        );
        Allocator allocator = Allocator(
            address(
                new TransparentUpgradeableProxy(
                    allocatorImpl, address(this), abi.encodeCall(Allocator.initialize, (address(mockAccessManager)))
                )
            )
        );
        return allocator;
    }

    function setUp() public virtual {
        _mockAssetRegistry = new MockAssetRegistry();

        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
        _mockAssetRegistry.mockRegisteredAsset(address(_mockGho));
        _mockUnsupportedAsset =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Asset", "tUNSUPPORTED", 18)));

        _defaultUsdtStrategy = new TestErc4626(_mockUsdt);
        _extraUsdtStrategy = new TestErc4626(_mockUsdt);
        _defaultGhoStrategy = new TestErc4626(_mockGho);
        _extraGhoStrategy = new TestErc4626(_mockGho);

        _mockAccessManager = new MockAccessManager(admin);

        _mockSwapper = new MockSwapper();
        _priceOracle = _deployPriceOracle(address(_mockAccessManager), 9_995e23);
        _mockTransferHelper = new MockTransferHelper();

        // Mock prices for assets (1 RAY = 1:1 price ratio)
        _mockAssetPrice(address(_priceOracle), address(_mockUsdt), MathLib.RAY);
        _mockAssetPrice(address(_priceOracle), address(_mockGho), MathLib.RAY);
        // Mock validatePrice to pass for any asset
        _mockValidatePriceForAll(address(_priceOracle));

        // Set up Asset Registry
        vm.prank(admin);
        _mockAssetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );
        vm.prank(admin);
        _mockAssetRegistry.setAssetConfig(
            address(_mockGho),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        _allocator = _deployAllocator(
            _mockAccessManager,
            address(_mockAssetRegistry),
            address(_priceOracle),
            address(_mockTransferHelper),
            MAX_STRATEGIES_PER_ASSET
        );

        // Set up strategy vaults
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(_extraUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockGho), address(_defaultGhoStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockGho), address(_extraGhoStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);

        vm.prank(everyRoleAccount);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
        vm.prank(everyRoleAccount);
        _allocator.setDefaultStrategy(address(_mockGho), address(_defaultGhoStrategy));
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        new Allocator(
            address(_mockAssetRegistry),
            depositor,
            withdrawer,
            address(_priceOracle),
            address(0),
            MAX_STRATEGIES_PER_ASSET
        );
    }

    function test_getTrustedAssetBalances_returnsExpectedAssetBalances(
        uint256 depositAmountUsdt,
        uint256 depositAmountGho
    ) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        _mockAssetRegistry.mockRegisteredAsset(address(_mockGho));
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        depositAmountGho = _boundAssetAmount(address(_mockGho), depositAmountGho);

        IAllocator.AllocatorBalance[] memory initialBalances = _allocator.getTrustedAssetBalances();
        bool foundUsdt = false;
        bool foundGho = false;
        for (uint256 i = 0; i < initialBalances.length; i++) {
            if (initialBalances[i].asset == address(_mockUsdt)) {
                foundUsdt = true;
                assertEq(initialBalances[i].amount, 0);
            } else if (initialBalances[i].asset == address(_mockGho)) {
                foundGho = true;
                assertEq(initialBalances[i].amount, 0);
            }
        }
        assertTrue(foundUsdt);
        assertTrue(foundGho);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        _mockTransferHelper.mockAsset(address(_mockGho), depositAmountGho);
        vm.prank(depositor);
        _allocator.deposit(address(_mockGho), depositAmountGho);

        IAllocator.AllocatorBalance[] memory balancesAfterDefaultDeposits = _allocator.getTrustedAssetBalances();
        assertEq(balancesAfterDefaultDeposits.length, 2);
        foundUsdt = false;
        foundGho = false;
        for (uint256 i = 0; i < balancesAfterDefaultDeposits.length; i++) {
            if (balancesAfterDefaultDeposits[i].asset == address(_mockUsdt)) {
                foundUsdt = true;
                assertEq(balancesAfterDefaultDeposits[i].amount, depositAmountUsdt);
            } else if (balancesAfterDefaultDeposits[i].asset == address(_mockGho)) {
                foundGho = true;
                assertEq(balancesAfterDefaultDeposits[i].amount, depositAmountGho);
            }
        }
        assertTrue(foundUsdt);
        assertTrue(foundGho);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Deposit some idle funds into the Allocator to ensure they are included in the balances
        uint256 idleFundsUsdt = 1000;
        _mockUsdt.mint(address(_allocator), idleFundsUsdt);
        uint256 idleFundsGho = 2000;
        _mockGho.mint(address(_allocator), idleFundsGho);

        IAllocator.AllocatorBalance[] memory balancesAfterIdleDeposits = _allocator.getTrustedAssetBalances();
        assertEq(balancesAfterIdleDeposits.length, 2);
        foundUsdt = false;
        foundGho = false;
        for (uint256 i = 0; i < balancesAfterIdleDeposits.length; i++) {
            if (balancesAfterIdleDeposits[i].asset == address(_mockUsdt)) {
                foundUsdt = true;
                assertEq(balancesAfterIdleDeposits[i].amount, depositAmountUsdt + idleFundsUsdt);
            } else if (balancesAfterIdleDeposits[i].asset == address(_mockGho)) {
                foundGho = true;
                assertEq(balancesAfterIdleDeposits[i].amount, depositAmountGho + idleFundsGho);
            }
        }
        assertTrue(foundUsdt);
        assertTrue(foundGho);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt + idleFundsUsdt);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmountGho + idleFundsGho);
        // Balance in vault should not change with idle funds
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Deposit funds into the extra vaults on behalf of the allocator
        _mockUsdt.mint(address(depositor), depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), depositAmountUsdt);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(depositAmountUsdt, address(_allocator));

        _mockGho.mint(address(depositor), depositAmountGho);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockGho)).approve(address(_extraGhoStrategy), depositAmountGho);
        vm.prank(depositor);
        _extraGhoStrategy.deposit(depositAmountGho, address(_allocator));

        IAllocator.AllocatorBalance[] memory balancesAfterExtraDeposits = _allocator.getTrustedAssetBalances();
        assertEq(balancesAfterExtraDeposits.length, 2);
        foundUsdt = false;
        foundGho = false;
        for (uint256 i = 0; i < balancesAfterExtraDeposits.length; i++) {
            if (balancesAfterExtraDeposits[i].asset == address(_mockUsdt)) {
                foundUsdt = true;
                // depositAmountUsdt was deposited into the default vault and the extra vault
                assertEq(balancesAfterExtraDeposits[i].amount, depositAmountUsdt * 2 + idleFundsUsdt);
            } else if (balancesAfterExtraDeposits[i].asset == address(_mockGho)) {
                foundGho = true;
                // depositAmountGho was deposited into the default vault and the extra vault
                assertEq(balancesAfterExtraDeposits[i].amount, depositAmountGho * 2 + idleFundsGho);
            }
        }
        assertTrue(foundUsdt);
        assertTrue(foundGho);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt * 2 + idleFundsUsdt);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmountGho * 2 + idleFundsGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), depositAmountGho);
    }

    function test_getTrustedAssetBalances_returnsExpectedAssetBalances_whenAssetIsNotRegistered() public {
        // Deposit funds of USDC, USDT into the Allocator
        uint256 amount = 1000;
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        _mockTransferHelper.mockAsset(address(_mockUnsupportedAsset), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUnsupportedAsset), amount);

        // Check that balances only return the registered asset
        IAllocator.AllocatorBalance[] memory balances = _allocator.getTrustedAssetBalances();
        assertEq(balances.length, 2);
        assertEq(balances[0].asset, address(_mockUsdt));
        assertEq(balances[0].amount, amount);
        assertEq(balances[1].asset, address(_mockGho));
        assertEq(balances[1].amount, 0);
    }

    function test_getDefaultStrategy_returnsExpectedDefaultVault() public view {
        assertEq(_allocator.getDefaultStrategy(address(_mockUsdt)), address(_defaultUsdtStrategy));
        assertEq(_allocator.getDefaultStrategy(address(_mockGho)), address(_defaultGhoStrategy));
    }

    function test_getStrategyConfig_returnsExpectedStrategyConfig() public view {
        assertEq(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).asset, address(_mockUsdt));
        assertEq(
            _allocator.getStrategyConfig(address(_defaultUsdtStrategy)).maxSlippageAmount, STRATEGY_MAX_SLIPPAGE_AMOUNT
        );
        assertEq(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).isRegistered, true);
        assertEq(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).depositAllowed, true);
        assertEq(_allocator.getStrategyConfig(address(_extraUsdtStrategy)).asset, address(_mockUsdt));
        assertEq(
            _allocator.getStrategyConfig(address(_extraUsdtStrategy)).maxSlippageAmount, STRATEGY_MAX_SLIPPAGE_AMOUNT
        );
    }

    function test_isStrategySupportedForAsset_returnsExpectedResult() public view {
        assertTrue(_allocator.isStrategySupportedForAsset(address(_mockUsdt), address(_defaultUsdtStrategy)));
        assertTrue(_allocator.isStrategySupportedForAsset(address(_mockUsdt), address(_extraUsdtStrategy)));
        assertTrue(_allocator.isStrategySupportedForAsset(address(_mockGho), address(_defaultGhoStrategy)));
        assertTrue(_allocator.isStrategySupportedForAsset(address(_mockGho), address(_extraGhoStrategy)));
        assertFalse(_allocator.isStrategySupportedForAsset(address(_mockUsdt), address(_defaultGhoStrategy)));
        assertFalse(_allocator.isStrategySupportedForAsset(address(_mockGho), address(_defaultUsdtStrategy)));
        assertFalse(_allocator.isStrategySupportedForAsset(address(_mockUsdt), address(_extraGhoStrategy)));
        assertFalse(_allocator.isStrategySupportedForAsset(address(_mockGho), address(_extraUsdtStrategy)));
        assertFalse(
            _allocator.isStrategySupportedForAsset(address(_mockUnsupportedAsset), address(_defaultUsdtStrategy))
        );
        assertFalse(_allocator.isStrategySupportedForAsset(address(_mockUnsupportedAsset), address(_extraUsdtStrategy)));
        assertFalse(
            _allocator.isStrategySupportedForAsset(address(_mockUnsupportedAsset), address(_defaultGhoStrategy))
        );
        assertFalse(_allocator.isStrategySupportedForAsset(address(_mockUnsupportedAsset), address(_extraGhoStrategy)));
    }

    function test_isStrategySupported_returnsExpectedResult() public {
        assertTrue(_allocator.isStrategySupported(address(_defaultUsdtStrategy)));
        assertTrue(_allocator.isStrategySupported(address(_extraUsdtStrategy)));
        assertTrue(_allocator.isStrategySupported(address(_defaultGhoStrategy)));
        assertTrue(_allocator.isStrategySupported(address(_extraGhoStrategy)));
        assertFalse(_allocator.isStrategySupported(makeAddr("NON_EXISTING_VAULT")));
    }

    function test_tryDepositToStrategy_reverts_onlySelf() public {
        vm.expectRevert(Errors.OnlySelf.selector);
        _allocator.tryDepositToStrategy(address(_mockUsdt), 100, address(_defaultUsdtStrategy));
    }

    function test_tryWithdrawFromStrategy_reverts_onlySelf() public {
        vm.expectRevert(Errors.OnlySelf.selector);
        _allocator.tryWithdrawFromStrategy(address(_mockUsdt), 100, address(_defaultUsdtStrategy));
    }

    function test_deposit_depositsFundsIntoDefaultVault(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.prank(depositor);
        uint256 netDeposit = _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        // Return value should equal deposit amount (no slippage in default strategy)
        assertEq(netDeposit, depositAmountUsdt);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_depositAllowIdle_depositsFundsIntoDefaultVault(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.depositAllowIdle(address(_mockUsdt), depositAmountUsdt);

        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_deposit_withAllowedAssetWithoutStrategy(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        // Add the asset to the mock AssetRegistry
        _mockAssetRegistry.mockToAllowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockTransferHelper.mockAsset(address(_mockUnsupportedAsset), amount);
        vm.prank(depositor);
        uint256 netDeposit = _allocator.deposit(address(_mockUnsupportedAsset), amount);

        // Return value should equal deposit amount (no strategy, funds idle)
        assertEq(netDeposit, amount);
        // Check the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUnsupportedAsset)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_deposit_ifDefaultStrategyIsAddressZero_fundsAreIdle(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        // Set the default strategy to address(0)
        vm.prank(address(everyRoleAccount));
        _allocator.setDefaultStrategy(address(_mockUsdt), address(0));

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.prank(depositor);
        vm.expectEmit(true, true, true, true);
        emit IAllocator.AssetLeftIdle(address(_mockUsdt), depositAmountUsdt);
        uint256 netDeposit = _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        // Return value should equal deposit amount (no strategy, funds idle)
        assertEq(netDeposit, depositAmountUsdt);
        // Check that the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_depositAllowIdle_ifDefaultStrategyIsAddressZero_fundsAreIdle(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        // Set the default strategy to address(0)
        vm.prank(address(everyRoleAccount));
        _allocator.setDefaultStrategy(address(_mockUsdt), address(0));

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.prank(depositor);
        vm.expectEmit(true, true, true, true);
        emit IAllocator.AssetLeftIdle(address(_mockUsdt), depositAmountUsdt);
        _allocator.depositAllowIdle(address(_mockUsdt), depositAmountUsdt);

        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_deposit_reverts_ifSharesMintedIsZero() public {
        uint256 depositAmountUsdt = 1000;
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        TestErc4626WithSlippage _strategyWithSlippage = new TestErc4626WithSlippage(_mockUsdt);
        // Set slippage higher than deposit amount to simulate 0 shares minted
        _strategyWithSlippage.setDepositSlippage(type(uint256).max);

        vm.startPrank(address(everyRoleAccount));
        _allocator.addStrategy(address(_mockUsdt), address(_strategyWithSlippage), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_strategyWithSlippage));
        vm.stopPrank();

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);
    }

    function test_deposit_returnsDepositAmount_ifNegativeSlippage() public {
        uint256 depositAmount = 100;
        uint256 bonusAmount = 5;

        TestErc4626WithSlippage _strategyWithBonus = new TestErc4626WithSlippage(_mockUsdt);
        // Simulate negative slippage (strategy gives more value)
        _strategyWithBonus.setDepositBonus(bonusAmount);

        vm.startPrank(address(everyRoleAccount));
        _allocator.addStrategy(address(_mockUsdt), address(_strategyWithBonus), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_strategyWithBonus));
        vm.stopPrank();

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmount);
        vm.prank(depositor);
        uint256 netDeposit = _allocator.deposit(address(_mockUsdt), depositAmount);

        // Return value should equal deposit amount because the net amount is capped at the deposit amount
        assertEq(netDeposit, depositAmount);

        // The actual balance in strategy should reflect the positive slippage
        assertEq(_allocator.getAssetBalanceInStrategy(address(_strategyWithBonus)), depositAmount + bonusAmount);
    }

    function test_deposit_reverts_ifSlippageExceedsThreshold() public {
        uint256 depositAmount = 100;
        uint256 slippageAmount = STRATEGY_MAX_SLIPPAGE_AMOUNT + 1; // 11, exceeds threshold of 10

        TestErc4626WithSlippage _strategyWithSlippage = new TestErc4626WithSlippage(_mockUsdt);
        // Set slippage to exceed the configured maxSlippageAmount
        _strategyWithSlippage.setDepositSlippage(slippageAmount);

        vm.startPrank(address(everyRoleAccount));
        _allocator.addStrategy(address(_mockUsdt), address(_strategyWithSlippage), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_strategyWithSlippage));
        vm.stopPrank();

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmount);
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmount);
    }

    function test_deposit_succeeds_ifSlippageWithinThreshold() public {
        uint256 depositAmount = 100;
        uint256 slippageAmount = STRATEGY_MAX_SLIPPAGE_AMOUNT;

        TestErc4626WithSlippage _strategyWithSlippage = new TestErc4626WithSlippage(_mockUsdt);
        // Set slippage exactly at the configured maxSlippageAmount
        _strategyWithSlippage.setDepositSlippage(slippageAmount);

        vm.startPrank(address(everyRoleAccount));
        _allocator.addStrategy(address(_mockUsdt), address(_strategyWithSlippage), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_strategyWithSlippage));
        vm.stopPrank();

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmount);
        vm.prank(depositor);
        uint256 netDeposit = _allocator.deposit(address(_mockUsdt), depositAmount);

        // Net deposit should reflect the slippage
        assertEq(netDeposit, depositAmount - slippageAmount);
    }

    function test_depositAllowIdle_doesNotRevert_ifSharesMintedIsZero() public {
        uint256 depositAmountUsdt = 1000;
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        TestErc4626WithSlippage _strategyWithSlippage = new TestErc4626WithSlippage(_mockUsdt);
        _strategyWithSlippage.setDepositSlippage(type(uint256).max);

        vm.startPrank(address(everyRoleAccount));
        _allocator.addStrategy(address(_mockUsdt), address(_strategyWithSlippage), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_strategyWithSlippage));
        vm.stopPrank();

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.expectEmit(true, true, true, true);
        emit IAllocator.AssetLeftIdle(address(_mockUsdt), depositAmountUsdt);
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositFailed(address(_strategyWithSlippage), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.depositAllowIdle(address(_mockUsdt), depositAmountUsdt);

        // Check that the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_deposit_reverts_whereVaultRejectsDeposit(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);

        // Mock the vault to reject the deposit
        vm.mockCallRevert(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.deposit.selector, depositAmountUsdt, address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositIntoStrategyFailed.selector, address(_defaultUsdtStrategy))
        );
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);
    }

    function test_depositAllowIdle_doesNotRevert_ifVaultRejectsDeposit(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);

        vm.mockCallRevert(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.deposit.selector, depositAmountUsdt, address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        vm.expectEmit(true, true, true, true);
        emit IAllocator.AssetLeftIdle(address(_mockUsdt), depositAmountUsdt);
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositFailed(address(_defaultUsdtStrategy), depositAmountUsdt);

        vm.prank(depositor);
        _allocator.depositAllowIdle(address(_mockUsdt), depositAmountUsdt);

        // Check that the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_deposit_reverts_ifNonDepositorCalls(address nonDepositor, uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(nonDepositor != depositor);
        _assumeNotProxyAdmin(nonDepositor, address(_allocator));

        _mockUsdt.mint(depositor, amount);
        vm.prank(nonDepositor);
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.deposit(address(_mockUsdt), amount);
    }

    function test_depositAllowIdle_reverts_ifNonDepositorCalls(address nonDepositor, uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(nonDepositor != depositor);
        _assumeNotProxyAdmin(nonDepositor, address(_allocator));

        _mockUsdt.mint(depositor, amount);
        vm.prank(nonDepositor);
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.depositAllowIdle(address(_mockUsdt), amount);
    }

    function test_deposit_reverts_ifAssetRegistryDoesNotAllowDepositIntoAllocator(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockTransferHelper.mockAsset(address(_mockUnsupportedAsset), amount);

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        vm.prank(depositor);
        _allocator.deposit(address(_mockUnsupportedAsset), amount);
    }

    function test_depositAllowIdle_reverts_ifAssetRegistryDoesNotAllowDepositIntoAllocator(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockTransferHelper.mockAsset(address(_mockUnsupportedAsset), amount);

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        vm.prank(depositor);
        _allocator.depositAllowIdle(address(_mockUnsupportedAsset), amount);
    }

    function test_deposit_reverts_ifAmountIsZero() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), 0);
    }

    function test_depositAllowIdle_doesNotRevert_ifAmountIsZero() public {
        vm.prank(depositor);
        _allocator.depositAllowIdle(address(_mockUsdt), 0);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_withdraw_reverts_givenMaxWithdrawReturnsZero() public {
        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(everyRoleAccount);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(mockStrategy));

        uint256 amount = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        // Airdrop the assets to the TransferHelper to simulate the assets being in the Allocator.
        _mockUsdt.mint(address(_mockTransferHelper), amount);
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Check that the balance in TransferHelper is the 0.
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), 0);
        // Check that the balance in the Allocator is the amount.
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        // Check that the balance in the strategy is the amount.
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockStrategy)), amount);

        mockStrategy.mockMaxWithdraw(0);
        mockStrategy.mockPreviewRedeem(0);

        // Withdraw an amount that is less than the amount in the strategy
        uint256 amountToWithdraw = amount / 2;
        vm.prank(withdrawer);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        _allocator.withdraw(address(_mockUsdt), amountToWithdraw);
    }

    function test_withdraw_withdrawsFromDefaultVault(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        uint256 amountRemaining = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > amountRemaining);

        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Perform partial withdrawal
        uint256 amountToWithdraw = amount - amountRemaining;
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountToWithdraw);

        // Check balances after partial withdrawal
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amountToWithdraw);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountRemaining);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amountRemaining);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Perform full withdrawal
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountRemaining);

        // Check balances after full withdrawal
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_withdraw_withdrawsFromMultipleStrategies(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        uint256 amountRemaining = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > amountRemaining);

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        // Deposit directly into the strategy on behalf of the Allocator
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Perform partial withdrawal
        uint256 amountToWithdraw = amount - amountRemaining;
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountToWithdraw);

        // Check balances after partial withdrawal
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amountToWithdraw);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountRemaining);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), amountRemaining);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Perform full withdrawal
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountRemaining);

        // Check balances after full withdrawal
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_withdraw_withdrawsFromMultipleStrategies_whenStrategyWithdrawalFails(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        // Deposit directly into the strategy on behalf of the Allocator
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Deposit into the default strategy as well (this one will fail during withdrawal)
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amount);
        vm.prank(depositor);
        // Deposit directly into the strategy on behalf of the Allocator
        _defaultUsdtStrategy.deposit(amount, address(_allocator));

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount * 2);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Mock the default strategy to fail during withdrawal
        vm.mockCallRevert(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.withdraw.selector, amount, address(_allocator), address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        // Perform withdrawal expecting the withdrawal from the default strategy to fail
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyWithdrawalFailed(address(_defaultUsdtStrategy), address(_mockUsdt), amount);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Check balances after first withdrawal
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Check that attempts to withdraw from non-default strategy is also wrapped in a try-catch
        TestErc4626 nonDefaultStrategy = new TestErc4626(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(nonDefaultStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);

        // Deposit into the non-default strategies
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(nonDefaultStrategy), amount);
        vm.prank(depositor);
        nonDefaultStrategy.deposit(amount, address(_allocator));

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount * 3);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(nonDefaultStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Even if withdrawal for one non-default strategy fails, attempts to withdraw from other non-default strategies
        vm.mockCallRevert(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.withdraw.selector, amount, address(_allocator), address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );
        vm.mockCallRevert(
            address(_extraUsdtStrategy),
            abi.encodeWithSelector(IERC4626.withdraw.selector, amount, address(_allocator), address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyWithdrawalFailed(address(_defaultUsdtStrategy), address(_mockUsdt), amount);
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyWithdrawalFailed(address(_extraUsdtStrategy), address(_mockUsdt), amount);

        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Check balances are withdrawn from the nonDefaultStrategy
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount * 2);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount * 2);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(nonDefaultStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_withdraw_usesIdleFundsOnly(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        uint256 amountRemaining = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > amountRemaining);

        // Airdrop funds to the Allocator so that it has idle funds
        _mockUsdt.mint(address(_allocator), amount);

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Perform partial withdrawal
        uint256 amountToWithdraw = amount - amountRemaining;

        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountToWithdraw);

        // Check balances after partial withdrawal
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amountToWithdraw);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountRemaining);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Perform full withdrawal
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountRemaining);

        // Check balances after full withdrawal
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_withdraw_usesIdleFundsFirst(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        uint256 amountRemaining = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > amountRemaining);

        uint256 totalDeposited = amount * 2;

        // Deposit funds into the strategy vault
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Airdrop funds to the Allocator so that it has idle funds
        _mockUsdt.mint(address(_allocator), amount);

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), totalDeposited);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Perform partial withdrawal
        uint256 amountToWithdraw = totalDeposited - amountRemaining;
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountToWithdraw);

        // Check balances after partial withdrawal (uses idle funds first)
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amountToWithdraw);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountRemaining);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amountRemaining);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Perform full withdrawal
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountRemaining);

        // Check balances after full withdrawal
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), totalDeposited);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_withdraw_reverts_ifDefaultVaultHasInsufficientFunds(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 0);

        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Perform withdrawal
        vm.prank(withdrawer);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        _allocator.withdraw(address(_mockUsdt), amount + 1);

        // Try again after airdropping funds to the Allocator
        _mockUsdt.mint(address(_allocator), amount);
        vm.prank(withdrawer);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        _allocator.withdraw(address(_mockUsdt), amount * 2 + 1);
    }

    function test_withdraw_reverts_ifStrategiesHaveInsufficientFunds(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 0);

        // Deposit funds into the strategy vault on behalf of the Allocator
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Perform withdrawal
        vm.prank(withdrawer);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        _allocator.withdraw(address(_mockUsdt), amount + 1);

        // Try again after airdropping funds to the Allocator
        _mockUsdt.mint(address(_allocator), amount);
        vm.prank(withdrawer);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        _allocator.withdraw(address(_mockUsdt), amount * 2 + 1);
    }

    function test_withdraw_reverts_ifAmountIsZero() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), 0);
    }

    function test_withdraw_reverts_ifAssetIsNotRegistered(uint256 amount) public {
        // Unsupported asset is not registered in the AssetRegistry
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        vm.prank(withdrawer);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.withdraw(address(_mockUnsupportedAsset), amount);

        vm.prank(withdrawer);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.withdraw(address(_mockUnsupportedAsset), amount);
    }

    function test_withdraw_reverts_ifAssetIsConfiguredAsStrategy() public {
        _mockAssetRegistry.mockRegisteredAsset(address(_defaultUsdtStrategy));
        uint256 amount = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        vm.prank(withdrawer);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_defaultUsdtStrategy)));
        _allocator.withdraw(address(_defaultUsdtStrategy), amount);
    }

    function test_withdraw_reverts_ifNonWithdrawerCalls(address nonWithdrawer, uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(nonWithdrawer != withdrawer);
        _assumeNotProxyAdmin(nonWithdrawer, address(_allocator));

        vm.prank(nonWithdrawer);
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.withdraw(address(_mockUsdt), amount);

        vm.prank(nonWithdrawer);
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.withdraw(address(_mockUsdt), amount);
    }

    function test_tryWithdrawFromStrategy_revert_ifNotCalledBySelf(address nonSelf) public {
        uint256 amount = 1000;
        vm.assume(nonSelf != address(_allocator));
        _assumeNotProxyAdmin(nonSelf, address(_allocator));

        vm.prank(nonSelf);
        vm.expectRevert(Errors.OnlySelf.selector);
        _allocator.tryWithdrawFromStrategy(address(_mockUsdt), amount, address(_defaultUsdtStrategy));
    }

    function test_withdraw_revertsWithInsufficientFundsWhenMaxWithdrawLessThanAmountAndNoOtherStrategies(uint256 amount)
        public
    {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 1);

        // Deploy a fresh allocator with only one strategy
        Allocator singleStrategyAllocator = _deployAllocator(
            _mockAccessManager,
            address(_mockAssetRegistry),
            address(_priceOracle),
            address(_mockTransferHelper),
            MAX_STRATEGIES_PER_ASSET
        );

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        singleStrategyAllocator.addStrategy(address(_mockUsdt), address(mockStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(everyRoleAccount);
        singleStrategyAllocator.setDefaultStrategy(address(_mockUsdt), address(mockStrategy));

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), amount);
        vm.prank(depositor);
        mockStrategy.deposit(amount, address(singleStrategyAllocator));

        // Set maxWithdraw to return half of the amount (simulating partial liquidity)
        uint256 maxWithdrawable = amount / 2;
        mockStrategy.mockMaxWithdraw(maxWithdrawable);

        // Try to withdraw full amount - should fail since only maxWithdrawable is liquid
        // and there are no other strategies to cover the difference
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        singleStrategyAllocator.withdraw(address(_mockUsdt), amount);
    }

    function test_withdraw_redeemsAllSharesFromDefaultStrategyWhenMaxWithdrawReturnsZero(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), amount);
        vm.prank(depositor);
        mockStrategy.deposit(amount, address(_allocator));

        // Set maxWithdraw to return 0 (this should trigger fallback to redeem all shares)
        mockStrategy.mockMaxWithdraw(0);

        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Check that the full amount was withdrawn via redeemAll fallback
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockStrategy)), 0);
    }

    function test_withdraw_continuesSearchingStrategiesWhenDefaultStrategyHasNoShares(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        MockErc4626Strategy mockDefaultStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockDefaultStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(everyRoleAccount);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(mockDefaultStrategy));

        // Do NOT deposit into the default strategy - it has no shares
        // Only deposit into the extra non-default strategy
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Default strategy has no shares, so maxWithdraw will naturally return 0
        // and redeemAll will return 0, then it should continue to extra strategy
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Check that funds were withdrawn from the extra strategy
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockDefaultStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
    }

    function test_withdraw_withdrawsFullAmountFromDefaultStrategyWhenMaxWithdrawGreaterThanOrEqualToAmount(uint256 amount)
        public
    {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), amount);
        vm.prank(depositor);
        mockStrategy.deposit(amount, address(_allocator));

        // Don't set custom maxWithdraw, use default which returns the full balance
        // This means maxWithdraw >= amount, so full amount should be withdrawn
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Check that the full amount was withdrawn
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockStrategy)), 0);
    }

    function test_withdraw_continuesSearchingStrategiesWhenDefaultStrategyMaxWithdrawReturnsZero(uint256 amount)
        public
    {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 2);

        MockErc4626Strategy mockDefaultStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockDefaultStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(everyRoleAccount);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(mockDefaultStrategy));

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockDefaultStrategy), amount);
        vm.prank(depositor);
        mockDefaultStrategy.deposit(amount, address(_allocator));

        // Additional deposit into extra non-default strategy
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Set maxWithdraw to 0 and make redeem revert on the default strategy
        // (when maxWithdraw is 0, the allocator does not attempt to withdraw from the strategy)
        mockDefaultStrategy.mockMaxWithdraw(0);
        uint256 actualFullBalanceAvailableInMockDefaultStrategy = amount - 1;
        mockDefaultStrategy.mockPreviewRedeem(actualFullBalanceAvailableInMockDefaultStrategy);

        vm.expectCall(
            address(mockDefaultStrategy),
            abi.encodeWithSelector(
                IERC4626.withdraw.selector,
                actualFullBalanceAvailableInMockDefaultStrategy,
                address(_allocator),
                address(_allocator)
            )
        );

        // Withdraw should fail on default but succeed on extra strategy
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Allow the test to read the acual balance.
        mockDefaultStrategy.discardPreviewRedeemMock();

        // Check that funds were withdrawn from the extra strategy instead
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockDefaultStrategy)), 1);
        // The single token that was left out of the mock default strategy was taken from the extra strategy (which
        // leaves the extra strategy with the amount that was taken from the default strategy).
        assertEq(
            _allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)),
            actualFullBalanceAvailableInMockDefaultStrategy
        );
    }

    function test_withdraw_withdrawsPartialFromDefaultStrategyWhenMaxWithdrawLessThanAmountRequested(uint256 amount)
        public
    {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 2);

        MockErc4626Strategy mockDefaultStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockDefaultStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(everyRoleAccount);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(mockDefaultStrategy));

        // Deposit into the mock default strategy (double the amount to ensure enough balance)
        _mockUsdt.mint(depositor, amount * 2);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockDefaultStrategy), amount * 2);
        vm.prank(depositor);
        mockDefaultStrategy.deposit(amount * 2, address(_allocator));

        // Also deposit into the extra non-default strategy
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Set maxWithdraw to half the amount on the default strategy
        uint256 partialWithdraw = amount / 2;
        mockDefaultStrategy.mockMaxWithdraw(partialWithdraw);

        // Try to withdraw full amount, it should take partialWithdraw from default and the rest from the extra strategy
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Check that funds were withdrawn from both strategies
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        // Default strategy should have amount * 2 - partialWithdraw remaining
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockDefaultStrategy)), amount * 2 - partialWithdraw);
        // Extra strategy should have amount - (amount - partialWithdraw) remaining
        uint256 expectedExtraRemaining = amount - (amount - partialWithdraw);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), expectedExtraRemaining);
    }

    function test_rebalance_reverts_ifNotAuthorized(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector, operator, address(_allocator), bytes4(IAllocator.rebalance.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_allocate_depositsIdleFundsIntoDefaultVault(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        _mockUsdt.mint(address(_allocator), amount);
        _mockGho.mint(address(_allocator), amount);

        // Check balances (non should be in any strategy vaults)
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(_getDepositIdleFundsRebalanceParams(address(_mockUsdt)));

        // Check balances (now all USDT should be in the default vault)
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(_getDepositIdleFundsRebalanceParams(address(_mockGho)));

        // Check balances (now all GHO should be in the default vault)
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_rebalance_allocate_reverts_ifStrategyIsNotSupportedForAsset(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockUnsupportedAsset.mint(address(_allocator), amount);
        IAllocator.RebalanceParams[] memory rebalanceParams =
            _getDepositIdleFundsRebalanceParams(address(_mockUnsupportedAsset));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_allocate_reverts_ifVaultRejectsDeposit(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        _mockUsdt.mint(address(_allocator), amount);

        vm.mockCallRevert(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.deposit.selector, amount, address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        IAllocator.RebalanceParams[] memory rebalanceParams = _getDepositIdleFundsRebalanceParams(address(_mockUsdt));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositIntoStrategyFailed.selector, address(_defaultUsdtStrategy))
        );
        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams);
    }

    function test_rabalance_allocate_ifAmountSpecified(uint256 amountUsdt, uint256 amountGho) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmount(address(_mockGho), amountGho);
        vm.assume(amountUsdt > 0);
        vm.assume(amountGho > 0);

        uint256 allocationAmountUsdt = 1234;
        uint256 allocationAmountGho = 5678;
        vm.assume(allocationAmountUsdt < amountUsdt);
        vm.assume(allocationAmountGho < amountGho);

        // Airdrop funds to the Allocator
        _mockUsdt.mint(address(_allocator), amountUsdt);
        _mockGho.mint(address(_allocator), amountGho);

        vm.prank(address(everyRoleAccount));
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.AllocationParams[] memory allocations = _initializeAllocationParams(2);
        allocations[0] = _buildAllocationParams(
            address(_mockUsdt), _allocator.getDefaultStrategy(address(_mockUsdt)), allocationAmountUsdt
        );
        allocations[1] = _buildAllocationParams(
            address(_mockGho), _allocator.getDefaultStrategy(address(_mockGho)), allocationAmountGho
        );
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), _initializeSwapParams(0), allocations);
        _allocator.rebalance(rebalanceParams);

        // Check balances after allocating to default strategy
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountUsdt);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), allocationAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), allocationAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Airdrop funds to the Allocator again
        _mockUsdt.mint(address(_allocator), amountUsdt);
        _mockGho.mint(address(_allocator), amountGho);

        rebalanceParams = _initializeRebalanceParams(1);
        allocations = _initializeAllocationParams(2);
        // Put funds into the non-default strategy
        allocations[0] = _buildAllocationParams(address(_mockUsdt), address(_extraUsdtStrategy), allocationAmountUsdt);
        allocations[1] = _buildAllocationParams(address(_mockGho), address(_extraGhoStrategy), allocationAmountGho);
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), _initializeSwapParams(0), allocations);
        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams);

        // Check balances after allocating to default strategy
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountUsdt * 2);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amountGho * 2);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), allocationAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), allocationAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), allocationAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), allocationAmountGho);
    }

    function test_rebalance_allocate_reverts_ifAmountGreaterThanBalance(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        vm.assume(amountUsdt > 0);

        // Airdrop funds to the Allocator
        _mockUsdt.mint(address(_allocator), amountUsdt);
        IAllocator.AllocationParams[] memory allocations = _initializeAllocationParams(1);
        allocations[0] = _buildAllocationParams(
            address(_mockUsdt), _allocator.getDefaultStrategy(address(_mockUsdt)), amountUsdt + 1
        );
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), _initializeSwapParams(0), allocations);
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAllocator.DepositIntoStrategyFailed.selector, _allocator.getDefaultStrategy(address(_mockUsdt))
            )
        );
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_deallocate_maxAmount(uint256 depositAmountUsdt, uint256 depositAmountGho) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        depositAmountGho = _boundAssetAmount(address(_mockGho), depositAmountGho);
        vm.assume(depositAmountUsdt > 0);
        vm.assume(depositAmountGho > 0);

        // Deposit funds into the strategy vault on behalf of the Allocator
        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), depositAmountUsdt);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(depositAmountUsdt, address(_allocator));

        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), depositAmountUsdt);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(depositAmountUsdt, address(_allocator));

        _mockGho.mint(depositor, depositAmountGho);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockGho)).approve(address(_defaultGhoStrategy), depositAmountGho);
        vm.prank(depositor);
        _defaultGhoStrategy.deposit(depositAmountGho, address(_allocator));

        _mockGho.mint(depositor, depositAmountGho);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockGho)).approve(address(_extraGhoStrategy), depositAmountGho);
        vm.prank(depositor);
        _extraGhoStrategy.deposit(depositAmountGho, address(_allocator));

        // Check balances before deallocation
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt * 2);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmountGho * 2);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), depositAmountGho);

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(4);
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), 0);
        deallocations[1] = _buildDeallocationParams(address(_mockUsdt), address(_extraUsdtStrategy), 0);
        deallocations[2] = _buildDeallocationParams(address(_mockGho), address(_defaultGhoStrategy), 0);
        deallocations[3] = _buildDeallocationParams(address(_mockGho), address(_extraGhoStrategy), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams);

        // Check balances after deallocating from default strategy
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt * 2);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmountGho * 2);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_rebalance_deallocate_zeroWithdawnIfShareBalanceIsZero() public {
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        // Submit max deallocation of the asset from the default strategy.
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_deallocate_specifiedAmount(uint256 depositAmountUsdt, uint256 depositAmountGho) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        depositAmountGho = _boundAssetAmount(address(_mockGho), depositAmountGho);
        vm.assume(depositAmountUsdt > 0);
        vm.assume(depositAmountGho > 0);

        uint256 deallocateAmountUsdt = 1234;
        uint256 deallocateAmountGho = 5678;
        vm.assume(deallocateAmountUsdt < depositAmountUsdt);
        vm.assume(deallocateAmountGho < depositAmountGho);

        // Deposit funds into the strategy vault on behalf of the Allocator
        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), depositAmountUsdt);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(depositAmountUsdt, address(_allocator));

        _mockGho.mint(depositor, depositAmountGho);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockGho)).approve(address(_defaultGhoStrategy), depositAmountGho);
        vm.prank(depositor);
        _defaultGhoStrategy.deposit(depositAmountGho, address(_allocator));

        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), depositAmountUsdt);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(depositAmountUsdt, address(_allocator));

        _mockGho.mint(depositor, depositAmountGho);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockGho)).approve(address(_extraGhoStrategy), depositAmountGho);
        vm.prank(depositor);
        _extraGhoStrategy.deposit(depositAmountGho, address(_allocator));

        // Check balances before deallocation
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt * 2);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmountGho * 2);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), depositAmountGho);

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(4);
        deallocations[0] =
            _buildDeallocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), deallocateAmountUsdt);
        deallocations[1] =
            _buildDeallocationParams(address(_mockUsdt), address(_extraUsdtStrategy), deallocateAmountUsdt);
        deallocations[2] =
            _buildDeallocationParams(address(_mockGho), address(_defaultGhoStrategy), deallocateAmountGho);
        deallocations[3] = _buildDeallocationParams(address(_mockGho), address(_extraGhoStrategy), deallocateAmountGho);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams);

        // Check balances after deallocation
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt * 2);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmountGho * 2);
        assertEq(
            _allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)),
            depositAmountUsdt - deallocateAmountUsdt
        );
        assertEq(
            _allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), depositAmountUsdt - deallocateAmountUsdt
        );
        assertEq(
            _allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), depositAmountGho - deallocateAmountGho
        );
        assertEq(
            _allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), depositAmountGho - deallocateAmountGho
        );
    }

    function test_rebalance_deallocate_specifiedAmount_reverts_ifStrategyDoesNotReturnSufficientAmount(uint256 depositAmountUsdt)
        public
    {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        vm.assume(depositAmountUsdt > 0);

        uint256 deallocateAmountUsdt = 1234;
        vm.assume(deallocateAmountUsdt < depositAmountUsdt);

        TestErc4626WithSlippage _strategyWithSlippage = new TestErc4626WithSlippage(_mockUsdt);

        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(_strategyWithSlippage), STRATEGY_MAX_SLIPPAGE_AMOUNT);

        // Deposit funds into the strategy vault on behalf of the Allocator
        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_strategyWithSlippage), depositAmountUsdt);
        vm.prank(depositor);
        _strategyWithSlippage.deposit(depositAmountUsdt, address(_allocator));

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] =
            _buildDeallocationParams(address(_mockUsdt), address(_strategyWithSlippage), deallocateAmountUsdt);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_deallocate_specifiedAmount_reverts_ifAmountGreaterThanBalance(uint256 depositAmountUsdt)
        public
    {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        vm.assume(depositAmountUsdt > 0);

        uint256 deallocateAmountUsdt = depositAmountUsdt + 1;
        vm.assume(deallocateAmountUsdt > depositAmountUsdt);

        // Deposit funds into the strategy vault on behalf of the Allocator
        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), depositAmountUsdt);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(depositAmountUsdt, address(_allocator));

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] =
            _buildDeallocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), deallocateAmountUsdt);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxWithdraw.selector,
                address(_allocator),
                deallocateAmountUsdt,
                depositAmountUsdt
            )
        );
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_deallocate_specifiedAmount_reverts_ifStrategyIsNotSupportedForAsset(
        address strategy,
        uint256 depositAmountUsdt
    ) public {
        depositAmountUsdt = _boundAssetAmountAllowingZero(address(_mockUsdt), depositAmountUsdt);
        vm.assume(!_allocator.isStrategySupportedForAsset(address(_mockUsdt), strategy));

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), strategy, depositAmountUsdt);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_swap_multipleCallsToSwapper(uint256 amountAssetInSwapOne, uint256 amountAssetInSwapTwo)
        public
    {
        address assetIn = address(_mockUsdt);
        address assetOut = address(_mockGho);
        amountAssetInSwapOne = _boundAssetAmount(assetIn, amountAssetInSwapOne);
        amountAssetInSwapTwo = _boundAssetAmount(assetIn, amountAssetInSwapTwo);
        uint256 amountAssetOutOne = amountAssetInSwapOne.convertAssetDecimals(assetIn, assetOut);
        uint256 amountAssetOutTwo = amountAssetInSwapTwo.convertAssetDecimals(assetIn, assetOut);
        vm.assume(amountAssetOutOne > 0);
        vm.assume(amountAssetOutTwo > 0);

        // Airdrop assetIn to the Allocator
        _mockUsdt.mint(address(_allocator), amountAssetInSwapOne + amountAssetInSwapTwo);

        // Mint assetOut to the swapper
        uint256 totalAmountOut = amountAssetOutOne + amountAssetOutTwo;
        _mockGho.mint(address(_mockSwapper), totalAmountOut);

        // Check balances before the swap
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetInSwapOne + amountAssetInSwapTwo);
        assertEq(_allocator.getAssetBalance(assetOut), 0);

        // invoke a swap
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(2);
        swaps[0] = _buildSwapParams(assetIn, amountAssetInSwapOne, assetOut, address(_mockSwapper), "");
        swaps[1] = _buildSwapParams(assetIn, amountAssetInSwapTwo, assetOut, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.AssetsSwapped(assetIn, assetOut, amountAssetInSwapOne, amountAssetOutOne);
        vm.expectEmit(true, true, true, true);
        emit IAllocator.AssetsSwapped(assetIn, assetOut, amountAssetInSwapTwo, amountAssetOutTwo);
        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams);

        // Check balances after the swap
        assertEq(_allocator.getAssetBalance(assetIn), 0);
        assertEq(_allocator.getAssetBalance(assetOut), totalAmountOut);
    }

    function test_rebalance_swap_reverts_ifNonZeroAmountTruncated(uint256 amountAssetIn) public {
        // assetIn has more decimals than assetOut
        address assetIn = address(_mockGho);
        address assetOut = address(_mockUsdt);
        amountAssetIn = _boundAssetAmount(assetIn, amountAssetIn);
        vm.assume(amountAssetIn > 0);
        vm.assume(amountAssetIn % 10 ** (AssetLib.getDecimals(assetIn) - AssetLib.getDecimals(assetOut)) != 0);

        // Airdrop assetIn to the swapper
        _mockGho.mint(address(_allocator), amountAssetIn);

        // Invoke a swap
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(assetIn, amountAssetIn, assetOut, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.InvalidAmount.selector);
        _allocator.rebalance(rebalanceParams);

        // Check balances
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetIn);
        assertEq(_allocator.getAssetBalance(assetOut), 0);
    }

    function test_rebalance_swap_reverts_ifAssetOutIncursSlippage(uint256 amountAssetInSwapOne) public {
        address assetIn = address(_mockUsdt);
        address assetOut = address(_mockGho);
        amountAssetInSwapOne = _boundAssetAmount(assetIn, amountAssetInSwapOne);
        uint256 amountAssetOut = amountAssetInSwapOne.convertAssetDecimals(assetIn, assetOut);
        vm.assume(amountAssetOut > 0);

        // Airdrop assetIn to the Allocator
        _mockUsdt.mint(address(_allocator), amountAssetInSwapOne);

        // Mint assetOut to the swapper
        _mockGho.mint(address(_mockSwapper), amountAssetOut);

        // Check balances before the swap
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetInSwapOne);
        assertEq(_allocator.getAssetBalance(assetOut), 0);

        // invoke a swap
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(assetIn, amountAssetInSwapOne, assetOut, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));

        // Mock slippage
        _mockSwapper.mockSlippage(true);

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        _allocator.rebalance(rebalanceParams);

        // Check balances after the swap to make sure of no change
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetInSwapOne);
        assertEq(_allocator.getAssetBalance(assetOut), 0);
    }

    function test_rebalance_swap_reverts_ifAssetInIsNotSupported() public {
        address assetIn = address(_mockUnsupportedAsset);
        address assetOut = address(_mockGho);
        uint256 amountAssetIn = 100_000_000;
        uint256 amountAssetOut = amountAssetIn.convertAssetDecimals(assetIn, assetOut);
        vm.assume(amountAssetOut > 0);

        // Airdrop assetIn to the Allocator
        _mockUnsupportedAsset.mint(address(_allocator), amountAssetIn);

        _mockAssetRegistry.mockToDisallowSwapInputToken(assetIn);

        // Invoke a swap
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(assetIn, amountAssetIn, assetOut, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, assetIn));
        _allocator.rebalance(rebalanceParams);

        // Check balances after the swap to make sure of no change
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetIn);
        assertEq(_allocator.getAssetBalance(assetOut), 0);
    }

    function test_rebalance_swap_reverts_ifAssetOutIsNotSupported() public {
        address assetIn = address(_mockUsdt);
        address assetOut = address(_mockUnsupportedAsset);
        uint256 amountAssetIn = 100_000_000;
        uint256 amountAssetOut = amountAssetIn.convertAssetDecimals(assetIn, assetOut);
        vm.assume(amountAssetOut > 0);

        // Airdrop assetIn to the Allocator
        _mockUsdt.mint(address(_allocator), amountAssetIn);

        _mockAssetRegistry.mockToDisallowSwapOutputToken(assetOut);

        // Invoke a swap
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(assetIn, amountAssetIn, assetOut, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, assetOut));
        _allocator.rebalance(rebalanceParams);

        // Check balances after the swap to make sure of no change
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetIn);
        assertEq(_allocator.getAssetBalance(assetOut), 0);
    }

    function test_rebalance_swap_reverts_ifInputAssetDustIsTruncated(uint256 amountAssetIn) public {
        address assetIn = address(_mockGho);
        address assetOut = address(_mockUsdt);
        amountAssetIn = _boundAssetAmount(assetIn, amountAssetIn);
        vm.assume(amountAssetIn > 0);
        vm.assume(amountAssetIn % 10 ** (AssetLib.getDecimals(assetIn) - AssetLib.getDecimals(assetOut)) != 0);

        // Airdrop assetIn to the Allocator
        _mockGho.mint(address(_allocator), amountAssetIn);

        // Invoke a swap
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(assetIn, amountAssetIn, assetOut, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.InvalidAmount.selector);
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_swap_succeeds_ifInputAssetDustIsNotTruncated(uint256 amountAssetIn) public {
        address assetIn = address(_mockGho);
        address assetOut = address(_mockUsdt);
        // Truncate amountAssetIn to the number of decimals of assetOut then convert back to assetIn decimals
        amountAssetIn = _boundAssetAmount(assetIn, amountAssetIn).convertAssetDecimals(assetIn, assetOut)
            .convertAssetDecimals(assetOut, assetIn);
        vm.assume(amountAssetIn > 0);

        // Airdrop assetIn to the Allocator
        _mockGho.mint(address(_allocator), amountAssetIn);

        // Mint assetOut to the swapper
        _mockUsdt.mint(address(_mockSwapper), amountAssetIn.convertAssetDecimals(assetIn, assetOut));

        // Invoke a swap
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(assetIn, amountAssetIn, assetOut, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));
        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams);

        // Check balances after the swap
        assertEq(_allocator.getAssetBalance(assetIn), 0);
        assertEq(_allocator.getAssetBalance(assetOut), amountAssetIn.convertAssetDecimals(assetIn, assetOut));
    }

    function test_rebalance_swap_reverts_ifAssetOutPriceIsInvalid() public {
        address assetIn = address(_mockUsdt);
        address assetOut = address(_mockGho);
        uint256 amountAssetIn = 100_000_000;

        // Airdrop assetIn to the Allocator
        _mockUsdt.mint(address(_allocator), amountAssetIn);

        // Mint assetOut to the swapper
        _mockGho.mint(address(_mockSwapper), amountAssetIn.convertAssetDecimals(assetIn, assetOut));

        _mockPriceTooLow(address(_priceOracle), assetOut);

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(assetIn, amountAssetIn, assetOut, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(IPriceOracle.PriceTooLow.selector);
        _allocator.rebalance(rebalanceParams);

        // Check balances after the swap
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetIn);
        assertEq(_allocator.getAssetBalance(assetOut), 0);
    }

    function test_rebalance_entireFlow(uint256 amountIn) public {
        address assetIn = address(_mockUsdt);
        address assetOut = address(_mockGho);

        amountIn = _boundAssetAmount(assetIn, amountIn);
        uint256 amountOut = amountIn.convertAssetDecimals(assetIn, assetOut);
        vm.assume(amountOut > 0);

        // Deposit assetIn into strategy vault on behalf of the Allocator
        _mockUsdt.mint(depositor, amountIn);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amountIn);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amountIn, address(_allocator));

        // Deposit assetOut into swapper
        _mockGho.mint(address(_mockSwapper), amountOut);

        // Check balances before the rebalance
        assertEq(_allocator.getAssetBalance(assetIn), amountIn);
        assertEq(_allocator.getAssetBalance(assetOut), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amountIn);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);

        // Invoke a rebalance where we need to deallocate, swap, and allocate
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] = _buildDeallocationParams(assetIn, address(_defaultUsdtStrategy), amountIn);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(assetIn, amountIn, assetOut, address(_mockSwapper), "");
        IAllocator.AllocationParams[] memory allocations = _initializeAllocationParams(1);
        allocations[0] = _buildAllocationParams(assetOut, address(_defaultGhoStrategy), amountOut);
        rebalanceParams[0] = _buildRebalanceParams(deallocations, swaps, allocations);
        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams);

        // Check balances after the rebalance
        assertEq(_allocator.getAssetBalance(assetIn), 0);
        assertEq(_allocator.getAssetBalance(assetOut), amountOut);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), amountOut);
    }

    function test_addStrategy_reverts_ifUnauthorizedCaller(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector, operator, address(_allocator), bytes4(IAllocator.addStrategy.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
    }

    function test_addStrategy_reverts_ifStrategyIsAlreadyAdded() public {
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressAlreadyWhitelisted.selector);
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
    }

    function test_addStrategy_reverts_ifAssetIsNotRegistered() public {
        address unsupportedStrategy = address(new TestErc4626(_mockUnsupportedAsset));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.addStrategy(
            address(_mockUnsupportedAsset), address(unsupportedStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT
        );
    }

    function test_addStrategy_reverts_ifStrategyIsNotSupportedForAsset() public {
        // Remove the extra strategy first to be able to add it back
        vm.prank(admin);
        _allocator.removeStrategy(address(_extraGhoStrategy));
        vm.prank(admin);
        _allocator.removeStrategy(address(_extraUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAsset.selector, address(_mockUsdt)));
        _allocator.addStrategy(address(_mockUsdt), address(_extraGhoStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAsset.selector, address(_mockGho)));
        _allocator.addStrategy(address(_mockGho), address(_extraUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
    }

    function test_addStrategy_reverts_ifMaxStrategiesPerAssetIsExceeded(uint8 maxStrategiesPerAsset) public {
        maxStrategiesPerAsset = uint8(bound(uint256(maxStrategiesPerAsset), 5, 20));

        _allocator = _deployAllocator(
            _mockAccessManager,
            address(_mockAssetRegistry),
            address(_priceOracle),
            address(_mockTransferHelper),
            maxStrategiesPerAsset
        );

        address strategy;
        for (uint256 i = 0; i < maxStrategiesPerAsset; i++) {
            strategy = address(new TestErc4626(_mockUsdt));
            vm.prank(address(everyRoleAccount));
            _allocator.addStrategy(address(_mockUsdt), address(strategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        }

        strategy = address(new TestErc4626(_mockUsdt));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(IAllocator.TooManyStrategies.selector, address(_mockUsdt)));
        _allocator.addStrategy(address(_mockUsdt), address(strategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
    }

    function test_setDefaultStrategy_reverts_ifUnauthorizedCaller(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_allocator),
                bytes4(IAllocator.setDefaultStrategy.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
    }

    function test_setDefaultStrategy_reverts_ifStrategyIsNotSupportedForAsset(address strategy) public {
        vm.assume(strategy != address(0));

        address asset = address(_mockUsdt);
        vm.assume(strategy != address(_defaultUsdtStrategy));
        vm.assume(strategy != address(_extraUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.setDefaultStrategy(asset, address(strategy));
    }

    function test_setDefaultStrategy_reverts_ifStrategyIsAlreadySet() public {
        address asset = address(_mockUsdt);
        address strategy = address(_defaultUsdtStrategy);

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(IAllocator.DefaultStrategy.selector, strategy));
        _allocator.setDefaultStrategy(asset, strategy);
    }

    function test_setDefaultStrategy_reverts_ifStrategyHasDepositsDisabled() public {
        vm.prank(admin);
        _allocator.disableDepositsToStrategy(address(_extraUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositsToStrategyDisabled.selector, address(_extraUsdtStrategy))
        );
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_extraUsdtStrategy));
    }

    function test_removeStrategy_reverts_ifDefaultStrategy() public {
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(IAllocator.DefaultStrategy.selector, address(_defaultUsdtStrategy)));
        _allocator.removeStrategy(address(_defaultUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(IAllocator.DefaultStrategy.selector, address(_defaultGhoStrategy)));
        _allocator.removeStrategy(address(_defaultGhoStrategy));
    }

    function test_removeStrategy_removesStrategyFromAssetStrategies() public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));

        // First set the default strategy to address(0) to remove the default strategy
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.DefaultStrategySet(address(_mockUsdt), address(0));
        _allocator.setDefaultStrategy(address(_mockUsdt), address(0));
        // Then remove the default strategy
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockUsdt), address(_defaultUsdtStrategy));
        _allocator.removeStrategy(address(_defaultUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockUsdt), address(_extraUsdtStrategy));
        _allocator.removeStrategy(address(_extraUsdtStrategy));

        // First set the default strategy to address(0) to remove the default strategy
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.DefaultStrategySet(address(_mockGho), address(0));
        _allocator.setDefaultStrategy(address(_mockGho), address(0));
        // Then remove the default strategy
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockGho), address(_defaultGhoStrategy));
        _allocator.removeStrategy(address(_defaultGhoStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockGho), address(_extraGhoStrategy));
        _allocator.removeStrategy(address(_extraGhoStrategy));

        // Check balance return 1 since USDT is still a supported asset in the AssetRegistry
        IAllocator.AllocatorBalance[] memory balances = _allocator.getTrustedAssetBalances();
        assertEq(balances.length, 2);
        assertEq(balances[0].asset, address(_mockUsdt));
        assertEq(balances[0].amount, 0);
        assertEq(balances[1].asset, address(_mockGho));
        assertEq(balances[1].amount, 0);

        // Add back a strategy and make it the default
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyAdded(address(_mockUsdt), address(_extraUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        _allocator.addStrategy(address(_mockUsdt), address(_extraUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.DefaultStrategySet(address(_mockUsdt), address(_extraUsdtStrategy));
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_extraUsdtStrategy));

        // Check the default strategy is the extra strategy
        assertEq(_allocator.getDefaultStrategy(address(_mockUsdt)), address(_extraUsdtStrategy));

        // Deposit funds into the allocator
        uint256 amount = 1000;
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Check the balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        balances = _allocator.getTrustedAssetBalances();
        assertEq(balances.length, 2);
        bool foundUsdt = false;
        bool foundGho = false;
        for (uint256 i = 0; i < balances.length; i++) {
            if (balances[i].asset == address(_mockUsdt)) {
                foundUsdt = true;
                assertEq(balances[i].amount, amount);
            }
            if (balances[i].asset == address(_mockGho)) {
                foundGho = true;
                assertEq(balances[i].amount, 0);
            }
        }
        assertTrue(foundUsdt);
        assertTrue(foundGho);
    }

    function test_removeStrategy_reverts_ifUnauthorizedCaller(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_allocator),
                bytes4(IAllocator.removeStrategy.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.removeStrategy(address(_defaultUsdtStrategy));
    }

    function test_removeStrategy_reverts_ifStrategyIsNotSupported(address strategy) public {
        vm.assume(strategy != address(_defaultUsdtStrategy));
        vm.assume(strategy != address(_extraUsdtStrategy));
        vm.assume(strategy != address(_defaultGhoStrategy));
        vm.assume(strategy != address(_extraGhoStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.removeStrategy(strategy);
    }

    function test_removeStrategy_reverts_ifStrategyHasFunds() public {
        // Deposit funds into the strategy
        uint256 amount = 1000;
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Swap out the default strategy for the extra strategy
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.DefaultStrategySet(address(_mockUsdt), address(_extraUsdtStrategy));
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_extraUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.StrategyStillHasFunds.selector, address(_defaultUsdtStrategy))
        );
        _allocator.removeStrategy(address(_defaultUsdtStrategy));
    }

    function test_disableDepositsToStrategy_preventsDepositsToStrategy() public {
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositsToggled(address(_defaultUsdtStrategy), false);
        vm.prank(address(everyRoleAccount));
        _allocator.disableDepositsToStrategy(address(_defaultUsdtStrategy));

        // Deposit funds into the allocator
        uint256 amount = 1000;
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositsToStrategyDisabled.selector, address(_defaultUsdtStrategy))
        );
        _allocator.deposit(address(_mockUsdt), amount);
    }

    function test_disableDepositsToStrategy_withMultiCall() public {
        bytes memory changeDefaultStrategyData = abi.encodeWithSelector(
            IAllocator.setDefaultStrategy.selector, address(_mockUsdt), address(_extraUsdtStrategy)
        );
        bytes memory disableDepositsToStrategyData =
            abi.encodeWithSelector(IAllocator.disableDepositsToStrategy.selector, address(_defaultUsdtStrategy));
        bytes[] memory data = new bytes[](2);
        data[0] = changeDefaultStrategyData;
        data[1] = disableDepositsToStrategyData;

        vm.prank(address(everyRoleAccount));
        bytes[] memory results = _allocator.multicall(data);
        assertEq(results.length, 2);

        // Deposit funds into the allocator
        uint256 amount = 1000;
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Check the balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_disableDepositsToStrategy_reverts_ifStrategyIsNotSupported() public {
        address strategy = makeAddr("newStrategy");
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.disableDepositsToStrategy(strategy);
    }

    function test_disableDepositsToStrategy_reverts_ifUnauthorizedCaller(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_allocator),
                bytes4(IAllocator.disableDepositsToStrategy.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.disableDepositsToStrategy(address(_defaultUsdtStrategy));
    }

    function test_enableDepositsToStrategy_enablesDepositsToStrategy() public {
        // First disable deposits to the strategy
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositsToggled(address(_defaultUsdtStrategy), false);
        vm.prank(address(everyRoleAccount));
        _allocator.disableDepositsToStrategy(address(_defaultUsdtStrategy));

        // Try to deposit into the strategy and it should fail
        uint256 amount = 1000;
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositsToStrategyDisabled.selector, address(_defaultUsdtStrategy))
        );
        _allocator.deposit(address(_mockUsdt), amount);

        // Then enable deposits to the strategy
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositsToggled(address(_defaultUsdtStrategy), true);
        vm.prank(address(everyRoleAccount));
        _allocator.enableDepositsToStrategy(address(_defaultUsdtStrategy));

        // Try to deposit into the strategy and it should succeed
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Check the balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_enableDepositsToStrategy_reverts_ifStrategyIsNotSupported() public {
        address strategy = makeAddr("newStrategy");
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.enableDepositsToStrategy(strategy);
    }

    function test_enableDepositsToStrategy_reverts_ifUnauthorizedCaller(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_allocator),
                bytes4(IAllocator.enableDepositsToStrategy.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.enableDepositsToStrategy(address(_defaultUsdtStrategy));
    }

    function test_topup_transfersFundsToAllocator(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        _mockUsdt.mint(everyRoleAccount, amount);

        uint256 allocatorBalanceBefore = _mockUsdt.balanceOf(address(_allocator));
        uint256 callerBalanceBefore = _mockUsdt.balanceOf(everyRoleAccount);

        vm.startPrank(everyRoleAccount);
        _mockUsdt.forceApprove(address(_allocator), amount);

        vm.expectEmit(true, false, false, true);
        emit IAllocator.AssetToppedUp(address(_mockUsdt), amount);
        vm.expectEmit(true, false, false, true);
        emit IAllocator.AssetLeftIdle(address(_mockUsdt), amount);
        _allocator.topup(address(_mockUsdt), amount);
        vm.stopPrank();

        assertEq(_mockUsdt.balanceOf(address(_allocator)), allocatorBalanceBefore + amount);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), callerBalanceBefore - amount);
    }

    function test_topup_increasesTotalAssetBalance(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        uint256 assetBalanceBefore = _allocator.getAssetBalance(address(_mockUsdt));

        _mockUsdt.mint(everyRoleAccount, amount);

        vm.startPrank(everyRoleAccount);
        _mockUsdt.forceApprove(address(_allocator), amount);
        _allocator.topup(address(_mockUsdt), amount);
        vm.stopPrank();

        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), assetBalanceBefore + amount);
    }

    function test_topup_reverts_ifNotAuthorized(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector, operator, address(_allocator), bytes4(IAllocator.topup.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.topup(address(_mockUsdt), 1);
    }

    function test_topup_reverts_ifAssetIsNotRegistered(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.topup(address(_mockUnsupportedAsset), amount);
    }

    function test_topup_reverts_ifAssetDepositToAllocatorNotAllowed(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUsdt));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUsdt)));
        _allocator.topup(address(_mockUsdt), amount);
    }

    function test_topup_reverts_ifZeroAmount() public {
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        _allocator.topup(address(_mockUsdt), 0);
    }

    function _getDepositIdleFundsRebalanceParams(address asset)
        internal
        view
        returns (IAllocator.RebalanceParams[] memory)
    {
        IAllocator.AllocationParams memory allocation =
            IAllocator.AllocationParams({asset: asset, strategy: _allocator.getDefaultStrategy(asset), amount: 0});
        IAllocator.AllocationParams[] memory allocations = new IAllocator.AllocationParams[](1);
        allocations[0] = allocation;
        IAllocator.RebalanceParams memory rebalanceParams = IAllocator.RebalanceParams({
            deallocations: new IAllocator.DeallocationParams[](0),
            swaps: new IAllocator.SwapParams[](0),
            allocations: allocations
        });
        IAllocator.RebalanceParams[] memory rebalances = new IAllocator.RebalanceParams[](1);
        rebalances[0] = rebalanceParams;
        return rebalances;
    }

    function _initializeDeallocationParams(uint16 length)
        internal
        pure
        returns (IAllocator.DeallocationParams[] memory)
    {
        return new IAllocator.DeallocationParams[](length);
    }

    function _buildDeallocationParams(address asset, address strategy, uint256 amount)
        internal
        pure
        returns (IAllocator.DeallocationParams memory)
    {
        return IAllocator.DeallocationParams({asset: asset, strategy: strategy, amount: amount});
    }

    function _initializeSwapParams(uint16 length) internal pure returns (IAllocator.SwapParams[] memory) {
        return new IAllocator.SwapParams[](length);
    }

    function _buildSwapParams(address assetIn, uint256 amountIn, address assetOut, address swapper, bytes memory data)
        internal
        pure
        returns (IAllocator.SwapParams memory)
    {
        return
            IAllocator.SwapParams({
                assetIn: assetIn, amountIn: amountIn, assetOut: assetOut, swapper: swapper, data: data
            });
    }

    function _initializeAllocationParams(uint16 length) internal pure returns (IAllocator.AllocationParams[] memory) {
        return new IAllocator.AllocationParams[](length);
    }

    function _buildAllocationParams(address asset, address strategy, uint256 amount)
        internal
        pure
        returns (IAllocator.AllocationParams memory)
    {
        return IAllocator.AllocationParams({asset: asset, strategy: strategy, amount: amount});
    }

    function _initializeRebalanceParams(uint16 length) internal pure returns (IAllocator.RebalanceParams[] memory) {
        return new IAllocator.RebalanceParams[](length);
    }

    function _buildRebalanceParams(
        IAllocator.DeallocationParams[] memory deallocations,
        IAllocator.SwapParams[] memory swaps,
        IAllocator.AllocationParams[] memory allocations
    ) internal pure returns (IAllocator.RebalanceParams memory) {
        return IAllocator.RebalanceParams({deallocations: deallocations, swaps: swaps, allocations: allocations});
    }
}
