// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Allocator} from "../src/common/Allocator.sol";
import {IAllocator} from "../src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "../src/interfaces/IAssetRegistry.sol";
import {AssetLib} from "../src/libraries/AssetLib.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {MathLib} from "../src/libraries/MathLib.sol";
import {TestWithHelpers} from "./helpers/TestWithHelpers.sol";
import {MockAccessManager} from "./mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "./mocks/MockAssetRegistry.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";
import {TestErc4626} from "./mocks/TestErc4626.sol";

import {console} from "forge-std/console.sol";

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
    TestErc4626 internal _defaultUsdtVault;
    TestErc4626 internal _extraUsdtVault;
    TestErc4626 internal _defaultGhoVault;
    TestErc4626 internal _extraGhoVault;

    Allocator internal _allocator;

    function _deployAllocator(MockAccessManager mockAccessManager, address assetRegistry) internal returns (Allocator) {
        address allocatorImpl = address(new Allocator(assetRegistry, depositor, withdrawer));
        Allocator allocator = Allocator(
            address(
                new TransparentUpgradeableProxy(
                    allocatorImpl, address(this), abi.encodeCall(Allocator.initialize, (address(mockAccessManager)))
                )
            )
        );

        // Set up strategy vaults
        vm.prank(admin);
        allocator.addVault(address(_mockUsdt), address(_defaultUsdtVault));
        vm.prank(admin);
        allocator.addVault(address(_mockUsdt), address(_extraUsdtVault));
        vm.prank(admin);
        allocator.addVault(address(_mockGho), address(_defaultGhoVault));
        vm.prank(admin);
        allocator.addVault(address(_mockGho), address(_extraGhoVault));

        vm.prank(everyRoleAccount);
        allocator.setDefaultVault(address(_mockUsdt), address(_defaultUsdtVault));
        vm.prank(everyRoleAccount);
        allocator.setDefaultVault(address(_mockGho), address(_defaultGhoVault));

        return allocator;
    }

    function setUp() public virtual {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
        _mockUnsupportedAsset =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Asset", "tUNSUPPORTED", 18)));

        _defaultUsdtVault = new TestErc4626(_mockUsdt);
        _extraUsdtVault = new TestErc4626(_mockUsdt);
        _defaultGhoVault = new TestErc4626(_mockGho);
        _extraGhoVault = new TestErc4626(_mockGho);

        _mockAssetRegistry = new MockAssetRegistry();
        _mockAccessManager = new MockAccessManager(admin);

        // Set up Asset Registry
        vm.prank(admin);
        _mockAssetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositIntoBBVAllowed: true,
                withdrawFromBBVAllowed: true,
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
                depositIntoBBVAllowed: true,
                withdrawFromBBVAllowed: true,
                depositIntoAllocatorAllowed: true,
                withdrawFromAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        _allocator = _deployAllocator(_mockAccessManager, address(_mockAssetRegistry));
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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Deposit USDT into the default vaults
        _mockUsdt.mint(depositor, depositAmountUsdt);
        // Approve the Allocator to spend the USDT
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_allocator), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        // Deposit GHO into the default vaults
        _mockGho.mint(depositor, depositAmountGho);
        // Approve the Allocator to spend the GHO
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockGho)).approve(address(_allocator), depositAmountGho);
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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Deposit funds into the extra vaults on half of the allocator
        _mockUsdt.mint(address(depositor), depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtVault), depositAmountUsdt);
        vm.prank(depositor);
        _extraUsdtVault.deposit(depositAmountUsdt, address(_allocator));

        _mockGho.mint(address(depositor), depositAmountGho);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockGho)).approve(address(_extraGhoVault), depositAmountGho);
        vm.prank(depositor);
        _extraGhoVault.deposit(depositAmountGho, address(_allocator));

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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), depositAmountGho);
    }

    function test_getDefaultVault_returnsExpectedDefaultVault() public view {
        assertEq(_allocator.getDefaultVault(address(_mockUsdt)), address(_defaultUsdtVault));
        assertEq(_allocator.getDefaultVault(address(_mockGho)), address(_defaultGhoVault));
    }

    function test_isVaultSupportedForAsset_returnsExpectedResult() public view {
        assertTrue(_allocator.isVaultSupportedForAsset(address(_mockUsdt), address(_defaultUsdtVault)));
        assertTrue(_allocator.isVaultSupportedForAsset(address(_mockUsdt), address(_extraUsdtVault)));
        assertTrue(_allocator.isVaultSupportedForAsset(address(_mockGho), address(_defaultGhoVault)));
        assertTrue(_allocator.isVaultSupportedForAsset(address(_mockGho), address(_extraGhoVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUsdt), address(_defaultGhoVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockGho), address(_defaultUsdtVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUsdt), address(_extraGhoVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockGho), address(_extraUsdtVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUnsupportedAsset), address(_defaultUsdtVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUnsupportedAsset), address(_extraUsdtVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUnsupportedAsset), address(_defaultGhoVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUnsupportedAsset), address(_extraGhoVault)));
    }

    function test_isVaultSupported_returnsExpectedResult() public {
        assertTrue(_allocator.isVaultSupported(address(_defaultUsdtVault)));
        assertTrue(_allocator.isVaultSupported(address(_extraUsdtVault)));
        assertTrue(_allocator.isVaultSupported(address(_defaultGhoVault)));
        assertTrue(_allocator.isVaultSupported(address(_extraGhoVault)));
        assertFalse(_allocator.isVaultSupported(makeAddr("NON_EXISTING_VAULT")));
    }

    function test_deposit_depositsFundsIntoDefaultVault(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_allocator), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);
    }

    function test_deposit_whereVaultRejectsDeposit(uint256 depositAmountUsdt) public {
        depositAmountUsdt = _boundAssetAmount(address(_mockUsdt), depositAmountUsdt);

        _mockUsdt.mint(depositor, depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_allocator), depositAmountUsdt);

        // Mock the vault to reject the deposit
        vm.mockCallRevert(
            address(_defaultUsdtVault),
            abi.encodeWithSelector(IERC4626.deposit.selector, depositAmountUsdt, address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        vm.expectEmit(true, true, true, true);
        emit IAllocator.VaultDepositFailed(address(_defaultUsdtVault), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        // Check the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);
    }

    function test_deposit_withAllowedAssetWithoutStrategy(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        // Add the asset to the mock AssetRegistry
        _mockAssetRegistry.mockToAllowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockUnsupportedAsset.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUnsupportedAsset)).approve(address(_allocator), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUnsupportedAsset), amount);

        // Check the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUnsupportedAsset)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);
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

        _mockUnsupportedAsset.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUnsupportedAsset)).approve(address(_allocator), amount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        vm.prank(depositor);
        _allocator.deposit(address(_mockUnsupportedAsset), amount);
    }

    function test_deposit_reverts_ifAmountIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), 0);
    }

    function test_depositIdleFunds_depositsIdleFundsIntoDefaultVault(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        _mockUsdt.mint(address(_allocator), amount);
        _mockGho.mint(address(_allocator), amount);

        // Check balances (non should be in any strategy vaults)
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        vm.prank(address(everyRoleAccount));
        _allocator.depositIdleFunds(address(_mockUsdt));

        // Check balances (now all USDT should be in the default vault)
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        vm.prank(address(everyRoleAccount));
        _allocator.depositIdleFunds(address(_mockGho));

        // Check balances (now all GHO should be in the default vault)
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);
    }

    function test_depositIdleFunds_reverts_ifAmountIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(address(everyRoleAccount));
        _allocator.depositIdleFunds(address(_mockUsdt));
    }

    function test_depositIdleFunds_reverts_ifDepositIsNotSupportedForAsset(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUnsupportedAsset));

        _mockUnsupportedAsset.mint(address(_allocator), amount);
        vm.prank(address(everyRoleAccount));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.depositIdleFunds(address(_mockUnsupportedAsset));
    }

    function test_depositIdleFunds_reverts_iffNonDepositorCalls(address nonDepositor, uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(nonDepositor != everyRoleAccount);
        vm.assume(nonDepositor != address(0));
        _assumeNotProxyAdmin(nonDepositor, address(_allocator));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                nonDepositor,
                address(_allocator),
                bytes4(keccak256("depositIdleFunds(address)"))
            ),
            abi.encode(false)
        );

        _mockUsdt.mint(address(_allocator), amount);
        vm.prank(nonDepositor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, nonDepositor));
        _allocator.depositIdleFunds(address(_mockUsdt));
    }

    function test_depositIdleFunds_reverts_ifVaultRejectsDeposit(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        _mockUsdt.mint(address(_allocator), amount);

        vm.mockCallRevert(
            address(_defaultUsdtVault),
            abi.encodeWithSelector(IERC4626.deposit.selector, amount, address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        vm.prank(address(everyRoleAccount));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.VaultDepositFailed.selector, address(_defaultUsdtVault), amount)
        );
        _allocator.depositIdleFunds(address(_mockUsdt));
    }

    function test_withdraw_withdrawsFromDefaultVault(uint256 amount) public {
        uint256 amountRemaining = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > amountRemaining);

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_allocator), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Perform partial withdrawal
        uint256 amountToWithdraw = amount - amountRemaining;
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountToWithdraw);

        // Check balances after partial withdrawal
        assertEq(_mockUsdt.balanceOf(withdrawer), amountToWithdraw);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountRemaining);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), amountRemaining);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Perform full withdrawal
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountRemaining);

        // Check balances after full withdrawal
        assertEq(_mockUsdt.balanceOf(withdrawer), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);
    }

    // TODO: withdraw from strategy vault
    function test_withdrawFromStrategyVault_withdrawsFromStrategyVault(uint256 amount) public {
        uint256 amountRemaining = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > amountRemaining);

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtVault), amount);
        vm.prank(depositor);
        // Deposit on behalf of the Allocator
        _extraUsdtVault.deposit(amount, address(_allocator));

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Perform partial withdrawal
        uint256 amountToWithdraw = amount - amountRemaining;
        vm.prank(withdrawer);
        _allocator.withdrawFromStrategy(address(_mockUsdt), amountToWithdraw, address(_extraUsdtVault));

        // Check balances after partial withdrawal
        assertEq(_mockUsdt.balanceOf(withdrawer), amountToWithdraw);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountRemaining);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), amountRemaining);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Perform full withdrawal
        vm.prank(withdrawer);
        _allocator.withdrawFromStrategy(address(_mockUsdt), amountRemaining, address(_extraUsdtVault));

        // Check balances after full withdrawal
        assertEq(_mockUsdt.balanceOf(withdrawer), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);
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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Perform partial withdrawal
        uint256 amountToWithdraw = amount - amountRemaining;

        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountToWithdraw);

        // Check balances after partial withdrawal
        assertEq(_mockUsdt.balanceOf(withdrawer), amountToWithdraw);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountRemaining);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Perform full withdrawal
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountRemaining);

        // Check balances after full withdrawal
        assertEq(_mockUsdt.balanceOf(withdrawer), amount);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);
    }

    function test_withdraw_usesIdleFundsFirst(uint256 amount) public {
        uint256 amountRemaining = 1000;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > amountRemaining);

        uint256 totalDeposited = amount * 2;

        // Deposit funds into the strategy vault
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_allocator), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Airdrop funds to the Allocator so that it has idle funds
        _mockUsdt.mint(address(_allocator), amount);

        // Check balances
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), totalDeposited);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), amount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Perform partial withdrawal
        uint256 amountToWithdraw = totalDeposited - amountRemaining;
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountToWithdraw);

        // Check balances after partial withdrawal (uses idle funds first)
        assertEq(_mockUsdt.balanceOf(withdrawer), amountToWithdraw);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), amountRemaining);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), amountRemaining);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Perform full withdrawal
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), amountRemaining);

        // Check balances after full withdrawal
        assertEq(_mockUsdt.balanceOf(withdrawer), totalDeposited);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdtVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);
    }

    function test_withdraw_reverts_ifDefaultVaultHasInsufficientFunds(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 0);

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_allocator), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        // Perform withdrawal
        vm.prank(withdrawer);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        _allocator.withdraw(address(_mockUsdt), amount + 1);

        // Try again after airdropping funds to the Allocator
        _mockUsdt.mint(address(_allocator), amount);
        vm.prank(withdrawer);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        _allocator.withdraw(address(_mockUsdt), amount * 2 + 1);
    }

    function test_withdrawFromStrategyVault_reverts_ifVaultHasInsufficientFunds(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 0);

        // Deposit funds into the strategy vault on behalf of the Allocator
        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdtVault), amount);
        vm.prank(depositor);
        _extraUsdtVault.deposit(amount, address(_allocator));

        // Perform withdrawal
        vm.prank(withdrawer);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        _allocator.withdrawFromStrategy(address(_mockUsdt), amount + 1, address(_extraUsdtVault));

        // Try again after airdropping funds to the Allocator
        _mockUsdt.mint(address(_allocator), amount);
        vm.prank(withdrawer);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        _allocator.withdrawFromStrategy(address(_mockUsdt), amount * 2 + 1, address(_extraUsdtVault));
    }

    function test_withdraw_reverts_ifAmountIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(withdrawer);
        _allocator.withdraw(address(_mockUsdt), 0);
    }

    function test_withdrawFromStrategyVault_reverts_ifAmountIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(withdrawer);
        _allocator.withdrawFromStrategy(address(_mockUsdt), 0, address(_extraUsdtVault));
    }

    function test_withdraw_reverts_ifVaultIsNotSupportedForAsset(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        vm.assume(amount > 0);

        _mockUsdt.mint(depositor, amount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_allocator), amount);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), amount);

        vm.prank(withdrawer);
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        // Specify the wrong vault for the asset
        _allocator.withdrawFromStrategy(address(_mockGho), amount, address(_defaultUsdtVault));
    }

    function test_withdrawFromStrategyVault_reverts_ifVaultIsNotSupportedForAsset(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUnsupportedAsset), amount);

        _mockAssetRegistry.mockToDisallowAssetWithdrawalsFromAllocator(address(_mockUnsupportedAsset));

        vm.prank(withdrawer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.withdraw(address(_mockUnsupportedAsset), amount);

        vm.prank(withdrawer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _allocator.withdrawFromStrategy(address(_mockUnsupportedAsset), amount, address(_extraUsdtVault));
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
        _allocator.withdrawFromStrategy(address(_mockUsdt), amount, address(_extraUsdtVault));
    }
}
