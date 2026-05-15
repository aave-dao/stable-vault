// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Allocator} from "src/core/Allocator.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {PolicyRegistry} from "src/periphery/PolicyRegistry.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockErc4626Strategy} from "test/mocks/MockErc4626Strategy.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockReentrantErc4626Strategy} from "test/mocks/MockReentrantErc4626Strategy.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";
import {TestErc4626} from "test/mocks/TestErc4626.sol";
import {TestErc4626AccrueOnDeposit} from "test/mocks/TestErc4626AccrueOnDeposit.sol";
import {TestErc4626WithSlippage} from "test/mocks/TestErc4626WithSlippage.sol";

contract AllocatorTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMockErc20;

    uint8 constant STRATEGY_DEPOSIT_SLIPPAGE_TOLERANCE = 10;

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
    PolicyRegistry internal _policyRegistry;

    function _deployAllocator(
        MockAccessManager mockAccessManager,
        address assetRegistry,
        address priceOracle,
        address transferHelper,
        uint8 maxStrategiesPerAsset,
        address policyRegistry
    ) internal returns (Allocator) {
        address allocatorImpl = address(
            new Allocator(
                assetRegistry, depositor, withdrawer, priceOracle, transferHelper, maxStrategiesPerAsset, policyRegistry
            )
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
        _policyRegistry = new PolicyRegistry(address(_mockAccessManager));

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
            MAX_STRATEGIES_PER_ASSET,
            address(_policyRegistry)
        );

        // Set up strategy vaults
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(_extraUsdtStrategy));
        vm.prank(admin);
        _allocator.addStrategy(address(_mockGho), address(_defaultGhoStrategy));
        vm.prank(admin);
        _allocator.addStrategy(address(_mockGho), address(_extraGhoStrategy));
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        new Allocator(
            address(_mockAssetRegistry),
            depositor,
            withdrawer,
            address(_priceOracle),
            address(0),
            MAX_STRATEGIES_PER_ASSET,
            address(_policyRegistry)
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

        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmountUsdt);
        _pullAndRouteToStrategy(address(_mockGho), address(_defaultGhoStrategy), depositAmountGho);

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
        // Pull idle funds of USDT and the unregistered asset into the Allocator.
        uint256 amount = 1000;
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        _mockAssetRegistry.mockToAllowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));
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

    function test_getStrategyConfig_returnsExpectedStrategyConfig() public view {
        assertEq(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).asset, address(_mockUsdt));
        assertEq(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).isRegistered, true);
        assertEq(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).depositAllowed, true);
        assertEq(_allocator.getStrategyConfig(address(_extraUsdtStrategy)).asset, address(_mockUsdt));
    }

    function test_getStrategiesForAsset_returnsExpectedStrategies() public view {
        address[] memory usdtStrategies = _allocator.getStrategiesForAsset(address(_mockUsdt));
        assertEq(usdtStrategies.length, 2);
        assertEq(usdtStrategies[0], address(_defaultUsdtStrategy));
        assertEq(usdtStrategies[1], address(_extraUsdtStrategy));

        address[] memory ghoStrategies = _allocator.getStrategiesForAsset(address(_mockGho));
        assertEq(ghoStrategies.length, 2);
        assertEq(ghoStrategies[0], address(_defaultGhoStrategy));
        assertEq(ghoStrategies[1], address(_extraGhoStrategy));
    }

    function test_getStrategiesForAsset_reflectsAddAndRemove() public {
        TestErc4626 newStrategy = new TestErc4626(_mockUsdt);

        address[] memory before = _allocator.getStrategiesForAsset(address(_mockUsdt));
        uint256 countBefore = before.length;

        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(newStrategy));

        address[] memory after_ = _allocator.getStrategiesForAsset(address(_mockUsdt));
        assertEq(after_.length, countBefore + 1);
        assertEq(after_[after_.length - 1], address(newStrategy));

        vm.prank(everyRoleAccount);
        _allocator.removeStrategy(address(newStrategy));

        address[] memory afterRemove = _allocator.getStrategiesForAsset(address(_mockUsdt));
        assertEq(afterRemove.length, countBefore);
    }

    function test_getStrategiesForAsset_returnsEmptyForUnknownAsset(address unknownAsset) public view {
        vm.assume(unknownAsset != address(_mockUsdt) && unknownAsset != address(_mockGho));
        address[] memory strategies = _allocator.getStrategiesForAsset(unknownAsset);
        assertEq(strategies.length, 0);
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

    function test_tryWithdrawFromStrategy_reverts_onlySelf() public {
        vm.expectRevert(Errors.OnlySelf.selector);
        _allocator.tryWithdrawFromStrategy(address(_mockUsdt), 100, address(_defaultUsdtStrategy));
    }

    function test_deposit_pullsToAllocatorAndEmitsIdle(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.prank(depositor);
        vm.expectEmit(true, true, true, true);
        emit IAllocator.AssetLeftIdle(address(_mockUsdt), depositAmountUsdt);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        // Funds always land idle on the Allocator regardless of any strategy configuration.
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_mockUsdt.balanceOf(address(_allocator)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_deposit_landsIdleWithoutStrategyConfigured(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        // Add the asset to the mock AssetRegistry but do not register a strategy for it.
        _mockAssetRegistry.mockToAllowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockTransferHelper.mockAsset(address(_mockUnsupportedAsset), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUnsupportedAsset), amount);

        // Check the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUnsupportedAsset)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_depositToStrategy_emitsAssetAllocatedWithSurplus_whenStrategyDonatesToFreshShares() public {
        uint256 amount = 100;
        uint256 bonus = 5;

        // The strategy attributes more value to the newly minted shares than was pulled (a deposit bonus
        // / donation), so `actualDepositedAmount > amount`. The Allocator must surface both values via
        // `AssetAllocated` so off-chain accounting can attribute the surplus to this strategy/asset.
        TestErc4626WithSlippage strategyWithBonus = new TestErc4626WithSlippage(_mockUsdt);
        strategyWithBonus.setDepositBonus(bonus);

        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(strategyWithBonus));

        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        vm.expectEmit(true, true, true, true);
        emit IAllocator.AssetAllocated(address(_mockUsdt), address(strategyWithBonus), amount, amount + bonus);
        _routeIdleToStrategy(address(_mockUsdt), address(strategyWithBonus), amount);
    }

    function test_getAssetBalanceInStrategy_returnsZero_ifPreviewRedeemReverts() public {
        uint256 depositAmount = 1000;
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy));

        // Deposit directly into the strategy so it holds shares for the Allocator
        _mockUsdt.mint(depositor, depositAmount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), depositAmount);
        vm.prank(depositor);
        mockStrategy.deposit(depositAmount, address(_allocator));

        // Confirm balance is reported correctly before breaking previewRedeem
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockStrategy)), depositAmount);

        // Now make previewRedeem revert — the tolerant _tryGetAssetBalanceInStrategy
        // used by getAssetBalanceInStrategy should return 0 instead of reverting
        mockStrategy.mockPreviewRedeemToRevert("broken");
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockStrategy)), 0);
    }

    function test_getAssetBalance_doesNotRevert_ifOneStrategyPreviewRedeemReverts() public {
        uint256 depositAmount = 1000;
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy));

        // Seed the healthy default strategy via direct ERC-4626 deposit.
        _mockUsdt.mint(depositor, depositAmount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), depositAmount);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(depositAmount, address(_allocator));

        // Deposit directly into the mock strategy so it holds shares for the Allocator
        _mockUsdt.mint(depositor, depositAmount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), depositAmount);
        vm.prank(depositor);
        mockStrategy.deposit(depositAmount, address(_allocator));

        // Total balance should include both strategies
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmount * 2);

        // Break previewRedeem on the mock strategy — getAssetBalance should still
        // return the healthy strategy's balance, skipping the broken one
        mockStrategy.mockPreviewRedeemToRevert("broken");
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmount);
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

    function test_deposit_reverts_ifAssetRegistryDoesNotAllowDepositIntoAllocator(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockTransferHelper.mockAsset(address(_mockUnsupportedAsset), amount);

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        vm.prank(depositor);
        _allocator.deposit(address(_mockUnsupportedAsset), amount);
    }

    function test_deposit_reverts_ifAmountIsZero() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), 0);
    }

    function test_withdraw_reverts_givenMaxWithdrawReturnsZero() public {
        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy));

        uint256 amount = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));

        // Seed the strategy with shares for the Allocator via direct ERC-4626 deposit.
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), amount);
        vm.prank(depositor);
        mockStrategy.deposit(amount, address(_allocator));

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

    function test_withdraw_withdrawsFromFirstStrategy(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        uint256 amountRemaining = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > amountRemaining);

        // Seed the first strategy in insertion order (_defaultUsdtStrategy) directly.
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amount);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amount, address(_allocator));

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

        // Mock the default strategy to fail during withdrawal (redeem is called via _withdrawFromStrategy)
        vm.mockCallRevert(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.redeem.selector, amount, address(_allocator), address(_allocator)),
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
        _allocator.addStrategy(address(_mockUsdt), address(nonDefaultStrategy));

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
            abi.encodeWithSelector(IERC4626.redeem.selector, amount, address(_allocator), address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );
        vm.mockCallRevert(
            address(_extraUsdtStrategy),
            abi.encodeWithSelector(IERC4626.redeem.selector, amount, address(_allocator), address(_allocator)),
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

        // Seed the first strategy directly so the Allocator owns shares.
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amount);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amount, address(_allocator));

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

    function test_withdraw_reverts_ifFirstStrategyHasInsufficientFunds(uint256 amount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 0);

        // Seed the first strategy directly so the Allocator owns shares.
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amount);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amount, address(_allocator));

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
            MAX_STRATEGIES_PER_ASSET,
            address(_policyRegistry)
        );

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        singleStrategyAllocator.addStrategy(address(_mockUsdt), address(mockStrategy));

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

    function test_withdraw_redeemsViaPreviewRedeemFallbackWhenMaxWithdrawReturnsZero(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy));

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), amount);
        vm.prank(depositor);
        mockStrategy.deposit(amount, address(_allocator));

        // maxWithdraw returns 0 (the strategy is signaling no liquidity through the standard view).
        // The Allocator falls back to _tryGetAssetBalanceInStrategy(previewRedeem) so a withdrawal
        // can still be serviced via the strategy's full balance.
        mockStrategy.mockMaxWithdraw(0);

        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Check that the full amount was withdrawn via the previewRedeem fallback path.
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockStrategy)), 0);
    }

    function test_withdraw_iteratesRemainingStrategiesWhenFirstStrategyHasNoShares(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        // _defaultUsdtStrategy is at index 0 with no shares; _extraUsdtStrategy at index 1 holds the funds.
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Withdraw should skip the empty first strategy and pull from the second.
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amount);

        // Check that funds were withdrawn from the extra strategy.
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
    }

    function test_withdraw_withdrawsFullAmountFromStrategyWhenMaxWithdrawGreaterThanOrEqualToAmount(uint256 amount)
        public
    {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy));

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

    function test_withdraw_continuesSearchingStrategiesWhenFirstStrategyMaxWithdrawReturnsZero(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 2);

        // Use a fresh allocator to control insertion order: brokenStrategy at idx 0, backupStrategy at idx 1.
        Allocator allocator = _deployAllocator(
            _mockAccessManager,
            address(_mockAssetRegistry),
            address(_priceOracle),
            address(_mockTransferHelper),
            MAX_STRATEGIES_PER_ASSET,
            address(_policyRegistry)
        );

        MockErc4626Strategy brokenStrategy = new MockErc4626Strategy(_mockUsdt);
        TestErc4626 backupStrategy = new TestErc4626(_mockUsdt);
        vm.prank(admin);
        allocator.addStrategy(address(_mockUsdt), address(brokenStrategy));
        vm.prank(admin);
        allocator.addStrategy(address(_mockUsdt), address(backupStrategy));

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(brokenStrategy), amount);
        vm.prank(depositor);
        brokenStrategy.deposit(amount, address(allocator));

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(backupStrategy), amount);
        vm.prank(depositor);
        backupStrategy.deposit(amount, address(allocator));

        // Set maxWithdraw to 0 on the first strategy; the previewRedeem fallback returns less than the
        // requested amount so the loop continues into the second strategy for the remainder.
        brokenStrategy.mockMaxWithdraw(0);
        uint256 actualFullBalanceAvailableInBrokenStrategy = amount - 1;
        brokenStrategy.mockPreviewRedeem(actualFullBalanceAvailableInBrokenStrategy);

        vm.expectCall(
            address(brokenStrategy),
            abi.encodeWithSelector(
                IERC4626.redeem.selector,
                actualFullBalanceAvailableInBrokenStrategy,
                address(allocator),
                address(allocator)
            )
        );

        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        allocator.withdraw(address(_mockUsdt), amount);

        // Allow the test to read the actual balance.
        brokenStrategy.discardPreviewRedeemMock();

        // Check that the remainder was withdrawn from the backup strategy.
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(allocator.getAssetBalanceInStrategy(address(brokenStrategy)), 1);
        assertEq(
            allocator.getAssetBalanceInStrategy(address(backupStrategy)), actualFullBalanceAvailableInBrokenStrategy
        );
    }

    function test_withdraw_withdrawsPartialFromFirstStrategyWhenMaxWithdrawLessThanAmountRequested(uint256 amount)
        public
    {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 2);

        // Use a fresh allocator to control insertion order: cappedStrategy at idx 0, backupStrategy at idx 1.
        Allocator allocator = _deployAllocator(
            _mockAccessManager,
            address(_mockAssetRegistry),
            address(_priceOracle),
            address(_mockTransferHelper),
            MAX_STRATEGIES_PER_ASSET,
            address(_policyRegistry)
        );

        MockErc4626Strategy cappedStrategy = new MockErc4626Strategy(_mockUsdt);
        TestErc4626 backupStrategy = new TestErc4626(_mockUsdt);
        vm.prank(admin);
        allocator.addStrategy(address(_mockUsdt), address(cappedStrategy));
        vm.prank(admin);
        allocator.addStrategy(address(_mockUsdt), address(backupStrategy));

        // Deposit into the capped first strategy (double the amount to ensure enough balance)
        _mockUsdt.mint(depositor, amount * 2);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(cappedStrategy), amount * 2);
        vm.prank(depositor);
        cappedStrategy.deposit(amount * 2, address(allocator));

        // Also deposit into the backup strategy
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(backupStrategy), amount);
        vm.prank(depositor);
        backupStrategy.deposit(amount, address(allocator));

        // Set maxWithdraw to half the amount on the first strategy.
        uint256 partialWithdraw = amount / 2;
        cappedStrategy.mockMaxWithdraw(partialWithdraw);

        // Withdraw full amount: takes partialWithdraw from idx 0 and the rest from idx 1.
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        vm.prank(withdrawer);
        allocator.withdraw(address(_mockUsdt), amount);

        // Check that funds were withdrawn from both strategies
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amount);
        assertEq(allocator.getAssetBalanceInStrategy(address(cappedStrategy)), amount * 2 - partialWithdraw);
        uint256 expectedBackupRemaining = amount - (amount - partialWithdraw);
        assertEq(allocator.getAssetBalanceInStrategy(address(backupStrategy)), expectedBackupRemaining);
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
        _allocator.rebalance(rebalanceParams, "");
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
        _allocator.rebalance(_getDepositIdleFundsRebalanceParams(address(_mockUsdt), address(_defaultUsdtStrategy)), "");

        // Check balances (now all USDT should be in the default vault)
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(_getDepositIdleFundsRebalanceParams(address(_mockGho), address(_defaultGhoStrategy)), "");

        // Check balances (now all GHO should be in the default vault)
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_rebalance_queriesRegistryWithRebalancePolicyId(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        _mockUsdt.mint(address(_allocator), amount);

        vm.expectCall(
            address(_policyRegistry),
            abi.encodeCall(IPolicyRegistry.getPolicy, keccak256("aave.stable-vault.Allocator.policy.rebalance"))
        );
        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(_getDepositIdleFundsRebalanceParams(address(_mockUsdt), address(_defaultUsdtStrategy)), "");
    }

    function test_rebalance_allocate_reverts_ifStrategyIsNotSupportedForAsset(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockUnsupportedAsset.mint(address(_allocator), amount);
        IAllocator.RebalanceParams[] memory rebalanceParams =
            _getDepositIdleFundsRebalanceParams(address(_mockUnsupportedAsset), address(_defaultUsdtStrategy));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.rebalance(rebalanceParams, "");
    }

    function test_rebalance_allocate_reverts_ifVaultRejectsDeposit(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        _mockUsdt.mint(address(_allocator), amount);

        vm.mockCallRevert(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.deposit.selector, amount, address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        IAllocator.RebalanceParams[] memory rebalanceParams =
            _getDepositIdleFundsRebalanceParams(address(_mockUsdt), address(_defaultUsdtStrategy));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositIntoStrategyFailed.selector, address(_defaultUsdtStrategy))
        );
        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams, "");
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
        allocations[0] = _buildAllocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), allocationAmountUsdt);
        allocations[1] = _buildAllocationParams(address(_mockGho), address(_defaultGhoStrategy), allocationAmountGho);
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), _initializeSwapParams(0), allocations);
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.rebalance(rebalanceParams, "");

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
        allocations[0] = _buildAllocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), amountUsdt + 1);
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), _initializeSwapParams(0), allocations);
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositIntoStrategyFailed.selector, address(_defaultUsdtStrategy))
        );
        _allocator.rebalance(rebalanceParams, "");
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
        _allocator.rebalance(rebalanceParams, "");

        // Check balances after deallocating from default strategy
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt * 2);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmountGho * 2);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_rebalance_deallocate_maxAmount_redeemsOnlyMaxRedeemableShares(
        uint256 depositAmountUsdt,
        uint256 maxRedeemableShares,
        uint256 yieldAmountUsdt
    ) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        vm.assume(depositAmountUsdt > 1);
        yieldAmountUsdt = bound(yieldAmountUsdt, 1, depositAmountUsdt * 20);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy));

        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), depositAmountUsdt);
        vm.prank(depositor);
        mockStrategy.deposit(depositAmountUsdt, address(_allocator));

        _mockUsdt.mint(address(mockStrategy), yieldAmountUsdt);

        uint256 sharesBalance = mockStrategy.balanceOf(address(_allocator));
        maxRedeemableShares = bound(maxRedeemableShares, 1, sharesBalance - 1);
        uint256 expectedRedeemedAssets = mockStrategy.previewRedeem(maxRedeemableShares);
        uint256 expectedRemainingAssets = depositAmountUsdt + yieldAmountUsdt - expectedRedeemedAssets;
        mockStrategy.mockMaxRedeem(maxRedeemableShares);

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(mockStrategy), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams, "");

        assertEq(_mockUsdt.balanceOf(address(_allocator)), expectedRedeemedAssets);
        assertEq(_mockUsdt.balanceOf(address(mockStrategy)), expectedRemainingAssets);
        assertEq(mockStrategy.balanceOf(address(_allocator)), sharesBalance - maxRedeemableShares);
    }

    function test_rebalance_deallocate_maxAmount_redeemsAllIfMaxRedeemReturnsZero(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        vm.assume(depositAmountUsdt > 0);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy));

        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), depositAmountUsdt);
        vm.prank(depositor);
        mockStrategy.deposit(depositAmountUsdt, address(_allocator));

        mockStrategy.mockMaxRedeem(0);

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(mockStrategy), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams, "");

        assertEq(_mockUsdt.balanceOf(address(_allocator)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockStrategy)), 0);
    }

    function test_rebalance_deallocate_reverts_redeemTotalBalanceSharesFromIlliquidStrategy(
        uint256 illiquidDepositAmountUsdt,
        uint256 liquidDepositAmountUsdt
    ) public {
        illiquidDepositAmountUsdt = _boundAssetAmount(address(_mockUsdt), illiquidDepositAmountUsdt);
        liquidDepositAmountUsdt = _boundAssetAmount(address(_mockUsdt), liquidDepositAmountUsdt);

        MockErc4626Strategy illiquidStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(illiquidStrategy));

        _mockUsdt.mint(depositor, illiquidDepositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(illiquidStrategy), illiquidDepositAmountUsdt);
        vm.prank(depositor);
        illiquidStrategy.deposit(illiquidDepositAmountUsdt, address(_allocator));

        _mockUsdt.mint(depositor, liquidDepositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), liquidDepositAmountUsdt);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(liquidDepositAmountUsdt, address(_allocator));

        illiquidStrategy.mockMaxRedeem(0);
        illiquidStrategy.mockRedeemToRevert("no liquidity");

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(2);
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(illiquidStrategy), 0);
        deallocations[1] = _buildDeallocationParams(address(_mockUsdt), address(_extraUsdtStrategy), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert("no liquidity");
        _allocator.rebalance(rebalanceParams, "");
    }

    function test_rebalance_deallocate_maxAmount_redeemsAllIfMaxRedeemEqualsShareBalance(uint256 depositAmountUsdt)
        public
    {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        MockErc4626Strategy mockStrategy = new MockErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(mockStrategy));

        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(mockStrategy), depositAmountUsdt);
        vm.prank(depositor);
        mockStrategy.deposit(depositAmountUsdt, address(_allocator));

        mockStrategy.mockMaxRedeem(mockStrategy.balanceOf(address(_allocator)));

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(mockStrategy), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(rebalanceParams, "");

        assertEq(_mockUsdt.balanceOf(address(_allocator)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(mockStrategy)), 0);
    }

    function test_rebalance_deallocate_maxAmount_reverts_ifShareBalanceIsZero() public {
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        // Submit max deallocation of the asset from the default strategy, which holds no shares for the Allocator.
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(IAllocator.ZeroShareBalance.selector, address(_defaultUsdtStrategy)));
        _allocator.rebalance(rebalanceParams, "");
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
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.addStrategy(address(_mockUsdt), address(_strategyWithSlippage));

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
        _allocator.rebalance(rebalanceParams, "");
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
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        _allocator.rebalance(rebalanceParams, "");
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
        _allocator.rebalance(rebalanceParams, "");
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
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.rebalance(rebalanceParams, "");
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
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.rebalance(rebalanceParams, "");

        // Check balances after the swap
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetIn);
        assertEq(_allocator.getAssetBalance(assetOut), 0);
    }

    function test_rebalance_swap_reverts_ifAssetInEqualsAssetOut() public {
        address asset = address(_mockUsdt);
        uint256 amountAssetIn = 100_000_000;
        _mockUsdt.mint(address(_allocator), amountAssetIn);

        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.SwapParams[] memory swaps = _initializeSwapParams(1);
        swaps[0] = _buildSwapParams(asset, amountAssetIn, asset, address(_mockSwapper), "");
        rebalanceParams[0] =
            _buildRebalanceParams(_initializeDeallocationParams(0), swaps, _initializeAllocationParams(0));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.InvalidParameter.selector);
        _allocator.rebalance(rebalanceParams, "");
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
        _allocator.rebalance(rebalanceParams, "");

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
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
    }

    function test_addStrategy_reverts_ifStrategyIsAlreadyAdded() public {
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressAlreadyWhitelisted.selector);
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
    }

    function test_addStrategy_reverts_ifAssetIsNotRegistered() public {
        address unsupportedStrategy = address(new TestErc4626(_mockUnsupportedAsset));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.addStrategy(address(_mockUnsupportedAsset), address(unsupportedStrategy));
    }

    function test_addStrategy_reverts_ifStrategyIsNotSupportedForAsset() public {
        // Remove the extra strategy first to be able to add it back
        vm.prank(admin);
        _allocator.removeStrategy(address(_extraGhoStrategy));
        vm.prank(admin);
        _allocator.removeStrategy(address(_extraUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAsset.selector, address(_mockUsdt)));
        _allocator.addStrategy(address(_mockUsdt), address(_extraGhoStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAsset.selector, address(_mockGho)));
        _allocator.addStrategy(address(_mockGho), address(_extraUsdtStrategy));
    }

    function test_addStrategy_reverts_ifMaxStrategiesPerAssetIsExceeded(uint8 maxStrategiesPerAsset) public {
        maxStrategiesPerAsset = uint8(bound(uint256(maxStrategiesPerAsset), 5, 20));

        _allocator = _deployAllocator(
            _mockAccessManager,
            address(_mockAssetRegistry),
            address(_priceOracle),
            address(_mockTransferHelper),
            maxStrategiesPerAsset,
            address(_policyRegistry)
        );

        address strategy;
        for (uint256 i = 0; i < maxStrategiesPerAsset; i++) {
            strategy = address(new TestErc4626(_mockUsdt));
            vm.prank(address(everyRoleAccount));
            _allocator.addStrategy(address(_mockUsdt), address(strategy));
        }

        strategy = address(new TestErc4626(_mockUsdt));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(IAllocator.TooManyStrategies.selector, address(_mockUsdt)));
        _allocator.addStrategy(address(_mockUsdt), address(strategy));
    }

    function test_removeStrategy_removesStrategyFromAssetStrategies() public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));

        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockUsdt), address(_defaultUsdtStrategy));
        _allocator.removeStrategy(address(_defaultUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockUsdt), address(_extraUsdtStrategy));
        _allocator.removeStrategy(address(_extraUsdtStrategy));

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

        // Add back a strategy and seed it directly.
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyAdded(address(_mockUsdt), address(_extraUsdtStrategy));
        _allocator.addStrategy(address(_mockUsdt), address(_extraUsdtStrategy));

        // Seed the strategy directly so the Allocator owns shares.
        uint256 amount = 1000;
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtStrategy), amount);
        vm.prank(depositor);
        _extraUsdtStrategy.deposit(amount, address(_allocator));

        // Check the balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), amount);

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
        // Seed the strategy directly so the Allocator owns shares in it.
        uint256 amount = 1000;
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amount);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amount, address(_allocator));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.StrategyStillHasFunds.selector, address(_defaultUsdtStrategy))
        );
        _allocator.removeStrategy(address(_defaultUsdtStrategy));
    }

    function test_disableDepositsToStrategy_preventsRebalanceAllocation() public {
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositsToggled(address(_defaultUsdtStrategy), false);
        vm.prank(address(everyRoleAccount));
        _allocator.disableDepositsToStrategy(address(_defaultUsdtStrategy));

        // Idle the funds in the Allocator and attempt to rebalance them into the disabled strategy.
        uint256 amount = 1000;
        _mockUsdt.mint(address(_allocator), amount);

        IAllocator.RebalanceParams[] memory params =
            _getDepositIdleFundsRebalanceParams(address(_mockUsdt), address(_defaultUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositsToStrategyDisabled.selector, address(_defaultUsdtStrategy))
        );
        _allocator.rebalance(params, "");
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

    function test_enableDepositsToStrategy_unblocksRebalanceAllocation() public {
        // First disable deposits to the strategy.
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositsToggled(address(_defaultUsdtStrategy), false);
        vm.prank(address(everyRoleAccount));
        _allocator.disableDepositsToStrategy(address(_defaultUsdtStrategy));

        // Idle the funds and confirm rebalance allocation is rejected while disabled.
        uint256 amount = 1000;
        _mockUsdt.mint(address(_allocator), amount);
        IAllocator.RebalanceParams[] memory params =
            _getDepositIdleFundsRebalanceParams(address(_mockUsdt), address(_defaultUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositsToStrategyDisabled.selector, address(_defaultUsdtStrategy))
        );
        _allocator.rebalance(params, "");

        // Then enable deposits to the strategy.
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositsToggled(address(_defaultUsdtStrategy), true);
        vm.prank(address(everyRoleAccount));
        _allocator.enableDepositsToStrategy(address(_defaultUsdtStrategy));

        // Now the same rebalance allocation succeeds.
        vm.prank(address(everyRoleAccount));
        _allocator.rebalance(params, "");

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

    function test_topUp_transfersFundsToAllocator(uint256 amount) public {
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
        _allocator.topUp(address(_mockUsdt), amount);
        vm.stopPrank();

        assertEq(_mockUsdt.balanceOf(address(_allocator)), allocatorBalanceBefore + amount);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), callerBalanceBefore - amount);
    }

    function test_topUp_increasesTotalAssetBalance(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        uint256 assetBalanceBefore = _allocator.getAssetBalance(address(_mockUsdt));

        _mockUsdt.mint(everyRoleAccount, amount);

        vm.startPrank(everyRoleAccount);
        _mockUsdt.forceApprove(address(_allocator), amount);
        _allocator.topUp(address(_mockUsdt), amount);
        vm.stopPrank();

        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), assetBalanceBefore + amount);
    }

    function test_topUp_reverts_ifNotAuthorized(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector, operator, address(_allocator), bytes4(IAllocator.topUp.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.topUp(address(_mockUsdt), 1);
    }

    function test_topUp_reverts_ifAssetIsNotRegistered(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);
        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.topUp(address(_mockUnsupportedAsset), amount);
    }

    function test_topUp_reverts_ifAssetDepositToAllocatorNotAllowed(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUsdt));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUsdt)));
        _allocator.topUp(address(_mockUsdt), amount);
    }

    function test_topUp_reverts_ifZeroAmount() public {
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        _allocator.topUp(address(_mockUsdt), 0);
    }

    function _getDepositIdleFundsRebalanceParams(address asset, address strategy)
        internal
        pure
        returns (IAllocator.RebalanceParams[] memory)
    {
        IAllocator.AllocationParams memory allocation =
            IAllocator.AllocationParams({asset: asset, strategy: strategy, amount: 0});
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

    /// @dev Routes idle balance of `asset` from the Allocator into `strategy` via a single-step rebalance.
    function _routeIdleToStrategy(address asset, address strategy, uint256 amount) internal {
        IAllocator.RebalanceParams[] memory params = new IAllocator.RebalanceParams[](1);
        params[0] = IAllocator.RebalanceParams({
            deallocations: new IAllocator.DeallocationParams[](0),
            swaps: new IAllocator.SwapParams[](0),
            allocations: new IAllocator.AllocationParams[](1)
        });
        params[0].allocations[0] = IAllocator.AllocationParams({asset: asset, strategy: strategy, amount: amount});
        vm.prank(everyRoleAccount);
        _allocator.rebalance(params, "");
    }

    /// @dev Pulls assets idle into the Allocator via the depositor and immediately routes them to `strategy`.
    function _pullAndRouteToStrategy(address asset, address strategy, uint256 amount) internal {
        _mockTransferHelper.mockAsset(asset, amount);
        vm.prank(depositor);
        _allocator.deposit(asset, amount);
        _routeIdleToStrategy(asset, strategy, amount);
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

    function test_trustStrategy_reverts_ifStrategyIsNotSupported() public {
        address strategy = makeAddr("newStrategy");
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.trustStrategy(strategy);
    }

    function test_trustStrategy_reverts_ifAlreadyTrusted() public {
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AlreadyTrusted.selector);
        _allocator.trustStrategy(address(_defaultUsdtStrategy));
    }

    function test_trustStrategy_reverts_ifUnauthorizedCaller(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_allocator),
                bytes4(IAllocator.trustStrategy.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.trustStrategy(address(_defaultUsdtStrategy));
    }

    function test_trustStrategy_setsIsTrustedToTrue() public {
        // First distrust
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));
        assertFalse(_allocator.isStrategyTrusted(address(_defaultUsdtStrategy)));

        // Then trust again
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyTrusted(address(_defaultUsdtStrategy));
        vm.prank(address(everyRoleAccount));
        _allocator.trustStrategy(address(_defaultUsdtStrategy));
        assertTrue(_allocator.isStrategyTrusted(address(_defaultUsdtStrategy)));
    }

    function test_distrustStrategy_reverts_ifStrategyIsNotSupported() public {
        address strategy = makeAddr("newStrategy");
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        _allocator.distrustStrategy(strategy);
    }

    function test_distrustStrategy_reverts_ifAlreadyDistrusted() public {
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.AlreadyDistrusted.selector);
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));
    }

    function test_distrustStrategy_reverts_ifUnauthorizedCaller(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_allocator),
                bytes4(IAllocator.distrustStrategy.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));
    }

    function test_distrustStrategy_setsIsTrustedToFalse() public {
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDistrusted(address(_defaultUsdtStrategy));
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));
        assertFalse(_allocator.isStrategyTrusted(address(_defaultUsdtStrategy)));
    }

    function test_distrustStrategy_doesNotAffectTotalAssetBalance(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);
        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        uint256 balanceBefore = _allocator.getAssetBalance(address(_mockUsdt));
        assertEq(balanceBefore, depositAmount);

        // Distrust the strategy
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        // getAssetBalance should still include the distrusted strategy
        uint256 balanceAfter = _allocator.getAssetBalance(address(_mockUsdt));
        assertEq(balanceAfter, depositAmount);
    }

    function test_distrustStrategy_excludesStrategyFromTrustedAssetBalance(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);
        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        assertEq(_allocator.getTrustedAssetBalance(address(_mockUsdt)), depositAmount);

        // Distrust the strategy
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        // getTrustedAssetBalance should exclude the distrusted strategy
        assertEq(_allocator.getTrustedAssetBalance(address(_mockUsdt)), 0);
    }

    function test_distrustStrategy_excludesStrategyFromTrustedAssetBalances(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);
        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        // Distrust the strategy
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        IAllocator.AllocatorBalance[] memory balances = _allocator.getTrustedAssetBalances();
        for (uint256 i = 0; i < balances.length; i++) {
            if (balances[i].asset == address(_mockUsdt)) {
                assertEq(balances[i].amount, 0);
            }
        }
    }

    function test_trustStrategy_restoresStrategyInTrustedAssetBalance(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);
        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        // Distrust and then trust
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));
        assertEq(_allocator.getTrustedAssetBalance(address(_mockUsdt)), 0);

        vm.prank(address(everyRoleAccount));
        _allocator.trustStrategy(address(_defaultUsdtStrategy));
        assertEq(_allocator.getTrustedAssetBalance(address(_mockUsdt)), depositAmount);
    }

    function test_getTrustedAssetBalance_returnsZero_whenAssetIsDistrusted(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);
        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        // Verify balance is non-zero before distrusting asset
        assertEq(_allocator.getTrustedAssetBalance(address(_mockUsdt)), depositAmount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmount);

        // Distrust the asset in the AssetRegistry
        _mockAssetRegistry.mockDistrustedAsset(address(_mockUsdt));

        // getTrustedAssetBalance should return 0 for a distrusted asset
        assertEq(_allocator.getTrustedAssetBalance(address(_mockUsdt)), 0);
        // getAssetBalance should still return the full balance
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmount);
    }

    function test_getTrustedAssetBalance_excludesDistrustedStrategy(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);
        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        // Verify baseline
        assertEq(_allocator.getTrustedAssetBalance(address(_mockUsdt)), depositAmount);

        // Distrust the strategy
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        // getTrustedAssetBalance should exclude the distrusted strategy's balance
        assertEq(_allocator.getTrustedAssetBalance(address(_mockUsdt)), 0);
        // getAssetBalance should still include it
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmount);
    }

    function test_addStrategy_setsIsTrustedToTrue() public {
        TestErc4626 newStrategy = new TestErc4626(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(newStrategy));
        assertTrue(_allocator.isStrategyTrusted(address(newStrategy)));
    }

    function test_isStrategyTrusted_returnsFalseForUnregisteredStrategy() public {
        assertFalse(_allocator.isStrategyTrusted(makeAddr("unregistered")));
    }

    function test_distrustStrategy_disablesDeposits() public {
        assertTrue(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).depositAllowed);

        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDistrusted(address(_defaultUsdtStrategy));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositsToggled(address(_defaultUsdtStrategy), false);
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        assertFalse(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).depositAllowed);
    }

    function test_distrustStrategy_doesNotRevertWhenDepositsAlreadyDisabled() public {
        // Disable deposits first
        vm.prank(address(everyRoleAccount));
        _allocator.disableDepositsToStrategy(address(_defaultUsdtStrategy));
        assertFalse(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).depositAllowed);

        // Distrust should succeed even though deposits are already disabled
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        assertFalse(_allocator.isStrategyTrusted(address(_defaultUsdtStrategy)));
        assertFalse(_allocator.getStrategyConfig(address(_defaultUsdtStrategy)).depositAllowed);
    }

    function test_distrustStrategy_preventsRebalanceAllocation(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);

        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        // deposit still lands funds idle on the Allocator regardless of strategy trust state.
        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(IERC20(address(_mockUsdt)).balanceOf(address(_allocator)), depositAmount);

        // Rebalance allocation into the distrusted strategy must be rejected.
        IAllocator.RebalanceParams[] memory params =
            _getDepositIdleFundsRebalanceParams(address(_mockUsdt), address(_defaultUsdtStrategy));
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositsToStrategyDisabled.selector, address(_defaultUsdtStrategy))
        );
        _allocator.rebalance(params, "");
    }

    function test_enableDepositsToStrategy_reverts_ifStrategyIsNotTrusted() public {
        // Distrust the strategy (this also disables deposits)
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        // Attempt to re-enable deposits while distrusted
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(IAllocator.StrategyNotTrusted.selector, address(_defaultUsdtStrategy)));
        _allocator.enableDepositsToStrategy(address(_defaultUsdtStrategy));
    }

    function test_trustStrategy_doesNotReEnableDeposits() public {
        // Distrust (auto-disables deposits)
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_extraUsdtStrategy));
        assertFalse(_allocator.getStrategyConfig(address(_extraUsdtStrategy)).depositAllowed);

        // Trusting again should NOT re-enable deposits
        vm.prank(address(everyRoleAccount));
        _allocator.trustStrategy(address(_extraUsdtStrategy));
        assertTrue(_allocator.isStrategyTrusted(address(_extraUsdtStrategy)));
        assertFalse(_allocator.getStrategyConfig(address(_extraUsdtStrategy)).depositAllowed);
    }

    function test_fullCycle_trustEnableDistrustTrustRequiresManualReEnable(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);

        // Strategy starts trusted with deposits enabled
        assertTrue(_allocator.isStrategyTrusted(address(_extraUsdtStrategy)));
        assertTrue(_allocator.getStrategyConfig(address(_extraUsdtStrategy)).depositAllowed);

        // 1. Distrust (auto-disables deposits)
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_extraUsdtStrategy));
        assertFalse(_allocator.isStrategyTrusted(address(_extraUsdtStrategy)));
        assertFalse(_allocator.getStrategyConfig(address(_extraUsdtStrategy)).depositAllowed);

        // 2. Trust again
        vm.prank(address(everyRoleAccount));
        _allocator.trustStrategy(address(_extraUsdtStrategy));
        assertTrue(_allocator.isStrategyTrusted(address(_extraUsdtStrategy)));
        // Deposits still disabled
        assertFalse(_allocator.getStrategyConfig(address(_extraUsdtStrategy)).depositAllowed);

        // 3. Manually re-enable deposits
        vm.prank(address(everyRoleAccount));
        _allocator.enableDepositsToStrategy(address(_extraUsdtStrategy));
        assertTrue(_allocator.getStrategyConfig(address(_extraUsdtStrategy)).depositAllowed);

        // 4. Deposit into the re-enabled strategy and verify balance
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);

        _mockUsdt.mint(address(_allocator), depositAmount);

        IAllocator.AllocationParams[] memory allocations = new IAllocator.AllocationParams[](1);
        allocations[0] = IAllocator.AllocationParams({
            asset: address(_mockUsdt), strategy: address(_extraUsdtStrategy), amount: depositAmount
        });
        IAllocator.RebalanceParams[] memory params = new IAllocator.RebalanceParams[](1);
        params[0] = IAllocator.RebalanceParams({
            deallocations: new IAllocator.DeallocationParams[](0),
            swaps: new IAllocator.SwapParams[](0),
            allocations: allocations
        });

        vm.prank(everyRoleAccount);
        _allocator.rebalance(params, "");

        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), depositAmount);
    }

    function test_removeStrategy_reverts_ifStrategyIsNotTrusted() public {
        // Distrust the strategy
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        // Attempt to remove should fail because the strategy is not trusted, so calls to it are not reliable
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(IAllocator.StrategyNotTrusted.selector, address(_defaultUsdtStrategy)));
        _allocator.removeStrategy(address(_defaultUsdtStrategy));
    }

    function test_depositToStrategy_reverts_ifStrategyIsDistrusted(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);

        // Distrust the extra strategy (not the default, so we can test rebalance allocation)
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_extraUsdtStrategy));

        // Try to allocate to distrusted strategy via rebalance
        _mockUsdt.mint(address(_allocator), depositAmount);

        IAllocator.AllocationParams[] memory allocations = new IAllocator.AllocationParams[](1);
        allocations[0] = IAllocator.AllocationParams({
            asset: address(_mockUsdt), strategy: address(_extraUsdtStrategy), amount: depositAmount
        });
        IAllocator.RebalanceParams[] memory params = new IAllocator.RebalanceParams[](1);
        params[0] = IAllocator.RebalanceParams({
            deallocations: new IAllocator.DeallocationParams[](0),
            swaps: new IAllocator.SwapParams[](0),
            allocations: allocations
        });

        vm.prank(everyRoleAccount);
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositsToStrategyDisabled.selector, address(_extraUsdtStrategy))
        );
        _allocator.rebalance(params, "");
    }

    function test_withdrawFromStrategy_succeedsWhenStrategyIsDistrusted(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockUsdt), depositAmount);
        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmount);

        // Distrust the strategy
        vm.prank(address(everyRoleAccount));
        _allocator.distrustStrategy(address(_defaultUsdtStrategy));

        // Withdrawal should still work
        _mockTransferHelper.mockAsset(address(_mockUsdt), 0);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), depositAmount);
    }

    //////////////////////////////////////////// REENTRANCY TESTS //////////////////////////////////////////////////////

    function _deployReentrantStrategy() internal returns (MockReentrantErc4626Strategy) {
        MockReentrantErc4626Strategy strategy = new MockReentrantErc4626Strategy(_mockUsdt);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(strategy));
        return strategy;
    }

    function _depositToReentrantStrategy(MockReentrantErc4626Strategy strategy, uint256 amount) internal {
        // Seed the reentrant strategy directly so the Allocator owns shares for subsequent deallocation.
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(strategy), amount);
        vm.prank(depositor);
        strategy.deposit(amount, address(_allocator));
    }

    function test_rebalance_reentrancyNotAllowedOnRebalanceViaWithdraw() public {
        uint256 depositAmount = 1000e6;
        MockReentrantErc4626Strategy reentrantStrategy = _deployReentrantStrategy();
        _depositToReentrantStrategy(reentrantStrategy, depositAmount);

        // Configure callback: during redeem() (called via _withdrawFromStrategy), call Allocator.rebalance() again
        reentrantStrategy.setReentrantCall(
            address(_allocator), abi.encodeCall(IAllocator.rebalance, (new IAllocator.RebalanceParams[](0), ""))
        );
        reentrantStrategy.setReentrancyOnRedeem(true);

        // Deallocate from the reentrant strategy → strategy.redeem() fires callback → reentry blocked
        IAllocator.DeallocationParams[] memory deallocations = new IAllocator.DeallocationParams[](1);
        deallocations[0] = IAllocator.DeallocationParams({
            asset: address(_mockUsdt), strategy: address(reentrantStrategy), amount: depositAmount
        });
        IAllocator.RebalanceParams[] memory params = new IAllocator.RebalanceParams[](1);
        params[0] =
            _buildRebalanceParams(deallocations, new IAllocator.SwapParams[](0), new IAllocator.AllocationParams[](0));

        vm.prank(admin);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        _allocator.rebalance(params, "");
    }

    function test_rebalance_reentrancyNotAllowedOnRebalanceViaRedeem() public {
        uint256 depositAmount = 1000e6;
        MockReentrantErc4626Strategy reentrantStrategy = _deployReentrantStrategy();
        _depositToReentrantStrategy(reentrantStrategy, depositAmount);

        // Configure callback: during redeem(), call Allocator.rebalance() again
        reentrantStrategy.setReentrantCall(
            address(_allocator), abi.encodeCall(IAllocator.rebalance, (new IAllocator.RebalanceParams[](0), ""))
        );
        reentrantStrategy.setReentrancyOnRedeem(true);

        // Deallocate with amount=0 triggers _redeemAllAvailableFromStrategy → strategy.redeem() fires callback
        IAllocator.DeallocationParams[] memory deallocations = new IAllocator.DeallocationParams[](1);
        deallocations[0] =
            IAllocator.DeallocationParams({asset: address(_mockUsdt), strategy: address(reentrantStrategy), amount: 0});
        IAllocator.RebalanceParams[] memory params = new IAllocator.RebalanceParams[](1);
        params[0] =
            _buildRebalanceParams(deallocations, new IAllocator.SwapParams[](0), new IAllocator.AllocationParams[](0));

        vm.prank(admin);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        _allocator.rebalance(params, "");
    }

    function _configureNonRevertingReentrantCallback(MockReentrantErc4626Strategy strategy) internal {
        strategy.setReentrantCall(
            address(_allocator), abi.encodeCall(IAllocator.rebalance, (new IAllocator.RebalanceParams[](0), ""))
        );
        strategy.setRevertOnReentrantFailure(false);
    }

    function test_withdraw_reentrancyNotAllowedOnRebalance() public {
        uint256 depositAmount = 1000e6;
        MockReentrantErc4626Strategy reentrantStrategy = _deployReentrantStrategy();
        _depositToReentrantStrategy(reentrantStrategy, depositAmount);

        // Configure non-reverting callback: during redeem() (called via _withdrawFromStrategy), try to call rebalance()
        _configureNonRevertingReentrantCallback(reentrantStrategy);
        reentrantStrategy.setReentrancyOnRedeem(true);

        _mockTransferHelper.mockAsset(address(_mockUsdt), 0);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), depositAmount);

        assertTrue(reentrantStrategy.lastReentrantCallReverted());
    }

    //////////////////////////////////////// ERC4626 ROUNDING LOSS (CS I-04) //////////////////////////////////////////

    /// @dev Simulates yield accrual by donating tokens directly to the strategy vault,
    /// which increases totalAssets without minting new shares, raising the share price.
    function _simulateStrategyYield(TestErc4626 strategy, IMockErc20 asset, uint256 yieldAmount) internal {
        asset.mint(address(strategy), yieldAmount);
    }

    function test_withdrawFromStrategy_retainsSurplusWhenSharePriceIs10x() public {
        uint256 depositAmount = 1_000_000e6;
        uint256 yieldAmount = 9_000_000e6; // 900% yield => sharePrice ≈ 10.0

        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        _simulateStrategyYield(_defaultUsdtStrategy, _mockUsdt, yieldAmount);

        uint256 sharesToBurn = _defaultUsdtStrategy.previewWithdraw(1);
        uint256 redeemValue = _defaultUsdtStrategy.previewRedeem(sharesToBurn);
        uint256 expectedSurplus = redeemValue - 1;
        assertEq(sharesToBurn, 1, "Should burn 1 share for 1 wei at 10x price");
        assertTrue(redeemValue >= 9, "1 share should be worth >= 9 wei at 10x");
        assertTrue(expectedSurplus >= 8, "Expected surplus should be >= 8 wei");

        _mockTransferHelper.mockAsset(address(_mockUsdt), 0);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), 1);

        uint256 idleBalance = _mockUsdt.balanceOf(address(_allocator));
        assertEq(idleBalance, expectedSurplus, "Allocator should retain rounding surplus as idle balance");
    }

    function test_withdrawFromStrategy_retainsSurplusWhenSharePriceIs2x() public {
        uint256 depositAmount = 1_000_000e6;
        uint256 yieldAmount = 1_000_000e6; // 100% yield => sharePrice ≈ 2.0

        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        _simulateStrategyYield(_defaultUsdtStrategy, _mockUsdt, yieldAmount);

        uint256 withdrawAmount = 10;
        uint256 sharesToBurn = _defaultUsdtStrategy.previewWithdraw(withdrawAmount);
        uint256 redeemValue = _defaultUsdtStrategy.previewRedeem(sharesToBurn);
        uint256 expectedSurplus = redeemValue - withdrawAmount;
        assertTrue(expectedSurplus > 0, "Should have positive surplus at 2x share price");

        _mockTransferHelper.mockAsset(address(_mockUsdt), 0);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), withdrawAmount);

        uint256 idleBalance = _mockUsdt.balanceOf(address(_allocator));
        assertEq(idleBalance, expectedSurplus, "Allocator should retain surplus at 2x share price");
    }

    function test_withdrawFromStrategy_retainsSurplusAcrossSharePrices(uint256 yieldMultiplier) public {
        yieldMultiplier = bound(yieldMultiplier, 2, 20); // 2x to 20x share price
        uint256 depositAmount = 1_000_000e6;
        uint256 yieldAmount = depositAmount * (yieldMultiplier - 1);

        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        _simulateStrategyYield(_defaultUsdtStrategy, _mockUsdt, yieldAmount);

        uint256 sharesToBurn = _defaultUsdtStrategy.previewWithdraw(1);
        uint256 redeemValue = _defaultUsdtStrategy.previewRedeem(sharesToBurn);
        uint256 expectedSurplus = redeemValue - 1;

        _mockTransferHelper.mockAsset(address(_mockUsdt), 0);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), 1);

        uint256 idleBalance = _mockUsdt.balanceOf(address(_allocator));
        assertEq(idleBalance, expectedSurplus, "Allocator should retain surplus across share prices");
    }

    /////////////////////////////////// SHARES CAP EDGE CASE (previewWithdraw > balanceOf) ////////////////////////////

    function test_withdrawFromStrategy_capsSharesAtBalance_whenPreviewWithdrawOverestimates() public {
        uint256 depositAmount = 1_000_000e6;

        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        uint256 sharesBalance = _defaultUsdtStrategy.balanceOf(address(_allocator));

        // Mock previewWithdraw to return 1 more share than the Allocator owns,
        // simulating a non-standard ERC4626 or rounding edge case.
        vm.mockCall(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.previewWithdraw.selector, depositAmount),
            abi.encode(sharesBalance + 1)
        );

        // Without the balanceOf cap, redeem(sharesBalance + 1) would revert with
        // ERC4626ExceededMaxRedeem. With the cap, redeem(sharesBalance) succeeds.
        _mockTransferHelper.mockAsset(address(_mockUsdt), 0);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), depositAmount);

        assertEq(
            _mockUsdt.balanceOf(address(_mockTransferHelper)),
            depositAmount,
            "Full amount should be transferred despite previewWithdraw overestimate"
        );
    }

    function test_withdrawFromStrategy_capsSharesAtBalance_revertsWhenAssetsInsufficient() public {
        uint256 depositAmount = 1_000_000e6;
        uint256 withdrawAmount = depositAmount + 1;

        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        // Try to deallocate more than deposited via rebalance (bypasses maxWithdraw check).
        // The cap kicks in: previewWithdraw(depositAmount+1) > sharesBalance, so
        // sharesToWithdraw = sharesBalance. redeem(sharesBalance) returns depositAmount,
        // but the require(actualAmount >= withdrawAmount) fails.
        IAllocator.RebalanceParams[] memory rebalanceParams = _initializeRebalanceParams(1);
        IAllocator.DeallocationParams[] memory deallocations = _initializeDeallocationParams(1);
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(_defaultUsdtStrategy), withdrawAmount);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        _allocator.rebalance(rebalanceParams, "");
    }

    function test_withdrawFromStrategy_capsSharesAtBalance_withYield() public {
        uint256 depositAmount = 1_000_000e6;
        uint256 yieldAmount = 1_000_000e6; // 2x share price

        _pullAndRouteToStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), depositAmount);

        _simulateStrategyYield(_defaultUsdtStrategy, _mockUsdt, yieldAmount);

        uint256 sharesBalance = _defaultUsdtStrategy.balanceOf(address(_allocator));
        uint256 maxWithdrawable = _defaultUsdtStrategy.maxWithdraw(address(_allocator));

        // Mock previewWithdraw to return sharesBalance + 1, simulating a strategy
        // where previewWithdraw overshoots by 1 due to aggressive ceil rounding.
        vm.mockCall(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.previewWithdraw.selector, maxWithdrawable),
            abi.encode(sharesBalance + 1)
        );

        // With the cap, redeem(sharesBalance) succeeds and returns all our assets
        // (which is >= maxWithdrawable since share price > 1).
        _mockTransferHelper.mockAsset(address(_mockUsdt), 0);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), maxWithdrawable);

        uint256 transferHelperBalance = _mockUsdt.balanceOf(address(_mockTransferHelper));
        assertGe(
            transferHelperBalance, maxWithdrawable, "Should successfully withdraw despite previewWithdraw overestimate"
        );
    }

    /////////////////////////////////////////////// RESCUE TOKENS //////////////////////////////////////////////////////

    function test_rescueTokens_rescuesUnregisteredNonStrategyToken(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockUnsupportedAsset.mint(address(_allocator), amount);

        vm.expectEmit(true, true, true, true);
        emit IRescuableToken.TokensRescued(address(_mockUnsupportedAsset), everyRoleAccount, amount);
        vm.prank(everyRoleAccount);
        IRescuableToken(address(_allocator)).rescueTokens(address(_mockUnsupportedAsset), amount);

        assertEq(_mockUnsupportedAsset.balanceOf(everyRoleAccount), amount);
        assertEq(_mockUnsupportedAsset.balanceOf(address(_allocator)), 0);
    }

    function test_rescueTokens_reverts_ifTokenIsRegistered(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        _mockUsdt.mint(address(_allocator), amount);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        IRescuableToken(address(_allocator)).rescueTokens(address(_mockUsdt), amount);
    }

    function test_rescueTokens_reverts_ifTokenIsStrategy() public {
        deal(address(_defaultUsdtStrategy), address(_allocator), 1000);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        IRescuableToken(address(_allocator)).rescueTokens(address(_defaultUsdtStrategy), 1000);
    }

    function test_rescueTokens_reverts_ifNotAuthorized(address unauthorizedMsgSender) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(_allocator));
        _mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(_allocator), IRescuableToken.rescueTokens.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableToken(address(_allocator)).rescueTokens(address(_mockUnsupportedAsset), 100);
    }

    ////////////////////////////////////////////////// HELPERS /////////////////////////////////////////////////////////

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
