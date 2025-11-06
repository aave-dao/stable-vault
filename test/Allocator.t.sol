// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

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
    TestErc4626 internal _defaultUsdcVault;
    TestErc4626 internal _extraUsdcVault;
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
        allocator.addVault(address(_mockUsdt), address(_defaultUsdcVault));
        vm.prank(admin);
        allocator.addVault(address(_mockUsdt), address(_extraUsdcVault));
        vm.prank(admin);
        allocator.addVault(address(_mockGho), address(_defaultGhoVault));
        vm.prank(admin);
        allocator.addVault(address(_mockGho), address(_extraGhoVault));

        vm.prank(everyRoleAccount);
        allocator.setDefaultVault(address(_mockUsdt), address(_defaultUsdcVault));
        vm.prank(everyRoleAccount);
        allocator.setDefaultVault(address(_mockGho), address(_defaultGhoVault));

        return allocator;
    }

    function setUp() public virtual {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
        _mockUnsupportedAsset =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Asset", "tUNSUPPORTED", 18)));

        _defaultUsdcVault = new TestErc4626(_mockUsdt);
        _extraUsdcVault = new TestErc4626(_mockUsdt);
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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdcVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdcVault)), 0);
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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdcVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdcVault)), 0);
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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdcVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdcVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), 0);

        // Deposit funds into the extra vaults on half of the allocator
        _mockUsdt.mint(address(depositor), depositAmountUsdt);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_extraUsdcVault), depositAmountUsdt);
        vm.prank(depositor);
        _extraUsdcVault.deposit(depositAmountUsdt, address(_allocator));

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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdcVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdcVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoVault)), depositAmountGho);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoVault)), depositAmountGho);
    }

    function test_getDefaultVault_returnsExpectedDefaultVault() public view {
        assertEq(_allocator.getDefaultVault(address(_mockUsdt)), address(_defaultUsdcVault));
        assertEq(_allocator.getDefaultVault(address(_mockGho)), address(_defaultGhoVault));
    }

    function test_isVaultSupportedForAsset_returnsExpectedResult() public view {
        assertTrue(_allocator.isVaultSupportedForAsset(address(_mockUsdt), address(_defaultUsdcVault)));
        assertTrue(_allocator.isVaultSupportedForAsset(address(_mockUsdt), address(_extraUsdcVault)));
        assertTrue(_allocator.isVaultSupportedForAsset(address(_mockGho), address(_defaultGhoVault)));
        assertTrue(_allocator.isVaultSupportedForAsset(address(_mockGho), address(_extraGhoVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUsdt), address(_defaultGhoVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockGho), address(_defaultUsdcVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUsdt), address(_extraGhoVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockGho), address(_extraUsdcVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUnsupportedAsset), address(_defaultUsdcVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUnsupportedAsset), address(_extraUsdcVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUnsupportedAsset), address(_defaultGhoVault)));
        assertFalse(_allocator.isVaultSupportedForAsset(address(_mockUnsupportedAsset), address(_extraGhoVault)));
    }

    function test_isVaultSupported_returnsExpectedResult() public {
        assertTrue(_allocator.isVaultSupported(address(_defaultUsdcVault)));
        assertTrue(_allocator.isVaultSupported(address(_extraUsdcVault)));
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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdcVault)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdcVault)), 0);
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
            address(_defaultUsdcVault),
            abi.encodeWithSelector(IERC4626.deposit.selector, depositAmountUsdt, address(_allocator)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(_allocator))
        );

        vm.expectEmit(true, true, true, true);
        emit IAllocator.VaultDepositFailed(address(_defaultUsdcVault), depositAmountUsdt);
        vm.prank(depositor);
        _allocator.deposit(address(_mockUsdt), depositAmountUsdt);

        // Check the funds are idle in the Allocator
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), depositAmountUsdt);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdcVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdcVault)), 0);
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
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdcVault)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraUsdcVault)), 0);
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

    // TODO: test add vault for asset where vault does not support the asset
}
