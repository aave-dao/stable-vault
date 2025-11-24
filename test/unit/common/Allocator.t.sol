// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Allocator} from "../../../src/common/Allocator.sol";
import {IAllocator} from "../../../src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "../../../src/interfaces/IAssetRegistry.sol";
import {AssetLib} from "../../../src/libraries/AssetLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {TestWithHelpers} from "../../helpers/TestWithHelpers.sol";
import {MockAccessManager} from "../../mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "../../mocks/MockAssetRegistry.sol";
import {IMockErc20} from "../../mocks/MockErc20.sol";
import {MockNonStandardErc20} from "../../mocks/MockNonStandardErc20.sol";
import {MockSwapper} from "../../mocks/MockSwapper.sol";
import {MockTransferHelper} from "../../mocks/MockTransferHelper.sol";
import {TestErc4626} from "../../mocks/TestErc4626.sol";
import {TestErc4626WithSlippage} from "../../mocks/TestErc4626WithSlippage.sol";

contract AllocatorTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMockErc20;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    // Represents the FH on Accounting Chain, Earning Chain Gateway on Earning Chain
    address depositor = makeAddr("DEPOSITOR");
    // Represents the FH on Accounting Chain, Earning Chain Gateway on Earning Chain
    address withdrawer = makeAddr("WITHDRAWER");

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
    MockTransferHelper internal _mockTransferHelper;

    Allocator internal _allocator;

    function _deployAllocator(MockAccessManager mockAccessManager, address assetRegistry, address transferHelper)
        internal
        returns (Allocator)
    {
        address allocatorImpl = address(new Allocator(assetRegistry, depositor, withdrawer, transferHelper));
        Allocator allocator = Allocator(
            address(
                new TransparentUpgradeableProxy(
                    allocatorImpl, address(this), abi.encodeCall(Allocator.initialize, (address(mockAccessManager)))
                )
            )
        );

        // Set up strategy vaults
        vm.prank(admin);
        allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
        vm.prank(admin);
        allocator.addStrategy(address(_mockUsdt), address(_extraUsdtStrategy));
        vm.prank(admin);
        allocator.addStrategy(address(_mockGho), address(_defaultGhoStrategy));
        vm.prank(admin);
        allocator.addStrategy(address(_mockGho), address(_extraGhoStrategy));

        vm.prank(everyRoleAccount);
        allocator.setDefaultStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
        vm.prank(everyRoleAccount);
        allocator.setDefaultStrategy(address(_mockGho), address(_defaultGhoStrategy));

        return allocator;
    }

    function setUp() public virtual {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
        _mockUnsupportedAsset =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Asset", "tUNSUPPORTED", 18)));

        _defaultUsdtStrategy = new TestErc4626(_mockUsdt);
        _extraUsdtStrategy = new TestErc4626(_mockUsdt);
        _defaultGhoStrategy = new TestErc4626(_mockGho);
        _extraGhoStrategy = new TestErc4626(_mockGho);

        _mockAssetRegistry = new MockAssetRegistry();
        _mockAccessManager = new MockAccessManager(admin);

        _mockSwapper = new MockSwapper();
        _mockTransferHelper = new MockTransferHelper();

        // Set up Asset Registry
        vm.prank(admin);
        _mockAssetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                withdrawToUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                withdrawFromAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );
        vm.prank(admin);
        _mockAssetRegistry.setAssetConfig(
            address(_mockGho),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                withdrawToUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                withdrawFromAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        _allocator = _deployAllocator(_mockAccessManager, address(_mockAssetRegistry), address(_mockTransferHelper));
    }

    function test_getAssetBalances_returnsExpectedAssetBalances(uint256 depositAmountUsdt, uint256 depositAmountGho)
        public
    {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        depositAmountGho = _boundAssetAmount(address(_mockGho), depositAmountGho);

        IAllocator.AllocatorBalance[] memory initialBalances = _allocator.getAssetBalances();
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

        IAllocator.AllocatorBalance[] memory balancesAfterDefaultDeposits = _allocator.getAssetBalances();
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

        IAllocator.AllocatorBalance[] memory balancesAfterIdleDeposits = _allocator.getAssetBalances();
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

        IAllocator.AllocatorBalance[] memory balancesAfterExtraDeposits = _allocator.getAssetBalances();
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

    function test_getDefaultStrategy_returnsExpectedDefaultVault() public view {
        assertEq(_allocator.getDefaultStrategy(address(_mockUsdt)), address(_defaultUsdtStrategy));
        assertEq(_allocator.getDefaultStrategy(address(_mockGho)), address(_defaultGhoStrategy));
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

    function test_deposit_depositsFundsIntoDefaultVault(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);
    }

    function test_deposit_whereVaultRejectsDeposit(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockTransferHelper.mockAsset(address(_mockUsdt), depositAmountUsdt);

        // Mock the vault to reject the deposit
        vm.mockCallRevert(
            address(_defaultUsdtStrategy),
            abi.encodeWithSelector(IERC4626.deposit.selector, depositAmountUsdt, address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyDepositFailed(address(_defaultUsdtStrategy), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        // Check the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
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

    function test_deposit_reverts_ifNonDepositorCalls(address nonDepositor, uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(nonDepositor != depositor);
        _assumeNotProxyAdmin(nonDepositor, address(_allocator));

        _mockUsdt.mint(depositor, amount);
        vm.prank(nonDepositor);
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        _allocator.deposit(address(_mockUsdt), amount);
    }

    function test_deposit_reverts_ifAssetRegistryDoesNotAllowDepositIntoAllocator(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockTransferHelper.mockAsset(address(_mockUnsupportedAsset), amount);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        vm.prank(depositor);
        _allocator.deposit(address(_mockUnsupportedAsset), amount);
    }

    function test_deposit_reverts_ifAmountIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), 0);
    }

    function test_withdraw_withdrawsFromDefaultVault(uint256 amount) public {
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

    function test_withdraw_usesIdleFundsOnly(uint256 amount) public {
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
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 0);

        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Perform withdrawal
        vm.prank(withdrawer);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        _allocator.withdraw(address(_mockUsdt), amount + 1);

        // Try again after airdropping funds to the Allocator
        _mockUsdt.mint(address(_allocator), amount);
        vm.prank(withdrawer);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        _allocator.withdraw(address(_mockUsdt), amount * 2 + 1);
    }

    function test_withdraw_reverts_ifStrategiesHaveInsufficientFunds(uint256 amount) public {
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
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        _allocator.withdraw(address(_mockUsdt), amount + 1);

        // Try again after airdropping funds to the Allocator
        _mockUsdt.mint(address(_allocator), amount);
        vm.prank(withdrawer);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        _allocator.withdraw(address(_mockUsdt), amount * 2 + 1);
    }

    function test_withdraw_reverts_ifAmountIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), 0);
    }

    function test_withdraw_reverts_ifVaultIsNotSupportedForAsset(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetWithdrawalsFromAllocator(address(_mockUnsupportedAsset));

        vm.prank(withdrawer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.withdraw(address(_mockUnsupportedAsset), amount);

        vm.prank(withdrawer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.withdraw(address(_mockUnsupportedAsset), amount);
    }

    function test_withdraw_reverts_ifNonWithdrawerCalls(address nonWithdrawer, uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(nonWithdrawer != withdrawer);
        _assumeNotProxyAdmin(nonWithdrawer, address(_allocator));

        vm.prank(nonWithdrawer);
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        _allocator.withdraw(address(_mockUsdt), amount);

        vm.prank(nonWithdrawer);
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        _allocator.withdraw(address(_mockUsdt), amount);
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
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
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
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(IAllocator.DepositIntoStrategyFailed.selector, address(_defaultUsdtStrategy), amount)
        );
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
        vm.expectRevert(ErrorsLib.InsufficientAmountOut.selector);
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_deallocate_maxAmount_reverts_ifStrategyDoesNotReturnSufficientAmount(uint256 depositAmountUsdt)
        public
    {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);
        vm.assume(depositAmountUsdt > 0);

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
        deallocations[0] = _buildDeallocationParams(address(_mockUsdt), address(_strategyWithSlippage), 0);
        rebalanceParams[0] =
            _buildRebalanceParams(deallocations, _initializeSwapParams(0), _initializeAllocationParams(0));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(ErrorsLib.InsufficientAmountOut.selector);
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
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
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
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
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
        vm.expectRevert(ErrorsLib.InsufficientAmountOut.selector);
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
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, assetIn));
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
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, assetOut));
        _allocator.rebalance(rebalanceParams);

        // Check balances after the swap to make sure of no change
        assertEq(_allocator.getAssetBalance(assetIn), amountAssetIn);
        assertEq(_allocator.getAssetBalance(assetOut), 0);
    }

    // TODO: test deallocate, swap, allocate
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
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
    }

    function test_addStrategy_reverts_ifStrategyIsAlreadyAdded() public {
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(ErrorsLib.AddressAlreadyWhitelisted.selector);
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
    }

    function test_addStrategy_reverts_ifStrategyIsNotSupportedForAsset() public {
        // Remove the extra strategy first to be able to add it back
        vm.prank(admin);
        _allocator.removeStrategy(address(_extraGhoStrategy));
        vm.prank(admin);
        _allocator.removeStrategy(address(_extraUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidAsset.selector, address(_mockUsdt)));
        _allocator.addStrategy(address(_mockUsdt), address(_extraGhoStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidAsset.selector, address(_mockGho)));
        _allocator.addStrategy(address(_mockGho), address(_extraUsdtStrategy));
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
        address asset = address(_mockUsdt);
        vm.assume(strategy != address(_defaultUsdtStrategy));
        vm.assume(strategy != address(_extraUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        _allocator.setDefaultStrategy(asset, address(strategy));
    }

    function test_setDefaultStrategy_reverts_ifStrategyIsAlreadySet() public {
        address asset = address(_mockUsdt);
        address strategy = address(_defaultUsdtStrategy);

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(ErrorsLib.AddressAlreadyWhitelisted.selector);
        _allocator.setDefaultStrategy(asset, strategy);
    }

    function test_removeStrategy_unsetsDefaultStrategy() public {
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.DefaultStrategySet(address(_mockUsdt), address(0));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockUsdt), address(_defaultUsdtStrategy));
        _allocator.removeStrategy(address(_defaultUsdtStrategy));
        assertEq(_allocator.getDefaultStrategy(address(_mockUsdt)), address(0));

        // If user deposits then funds sit idle
        uint256 amount = 1000;
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.DefaultStrategySet(address(_mockGho), address(0));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockGho), address(_defaultGhoStrategy));
        _allocator.removeStrategy(address(_defaultGhoStrategy));
        assertEq(_allocator.getDefaultStrategy(address(_mockGho)), address(0));
    }

    function test_removeStrategy_removesStrategyFromAssetStrategies() public {
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.DefaultStrategySet(address(_mockUsdt), address(0));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockUsdt), address(_defaultUsdtStrategy));
        _allocator.removeStrategy(address(_defaultUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockUsdt), address(_extraUsdtStrategy));
        _allocator.removeStrategy(address(_extraUsdtStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.DefaultStrategySet(address(_mockGho), address(0));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockGho), address(_defaultGhoStrategy));
        _allocator.removeStrategy(address(_defaultGhoStrategy));

        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyRemoved(address(_mockGho), address(_extraGhoStrategy));
        _allocator.removeStrategy(address(_extraGhoStrategy));

        // Check balance return 0 since internal __assetsWithSupportedStrategies is empty
        IAllocator.AllocatorBalance[] memory balances = _allocator.getAssetBalances();
        assertEq(balances.length, 0);

        // Add back a strategy and make it the default
        vm.prank(address(everyRoleAccount));
        vm.expectEmit(true, true, true, true);
        emit IAllocator.StrategyAdded(address(_mockUsdt), address(_extraUsdtStrategy));
        _allocator.addStrategy(address(_mockUsdt), address(_extraUsdtStrategy));
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

        balances = _allocator.getAssetBalances();
        assertEq(balances.length, 1);
        bool foundUsdt = false;
        bool foundGho = false;
        for (uint256 i = 0; i < balances.length; i++) {
            if (balances[i].asset == address(_mockUsdt)) {
                foundUsdt = true;
                assertEq(balances[i].amount, amount);
            }
            if (balances[i].asset == address(_mockGho)) {
                foundGho = true;
            }
        }
        assertTrue(foundUsdt);
        assertFalse(foundGho);
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
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        _allocator.removeStrategy(strategy);
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
