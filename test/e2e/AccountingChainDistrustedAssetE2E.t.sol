// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Logger} from "test/helpers/Logger.sol";

import {StableVault} from "src/core/accounting/StableVault.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Errors} from "src/types/Errors.sol";

import {BaseTest} from "test/BaseTest.t.sol";

/// @title AccountingChainDistrustedAssetE2ETest
/// @notice Test the withdrawal of funds on the Accounting Chain when an asset is distrusted.
contract AccountingChainDistrustedAssetE2ETest is BaseTest {
    using AssetLib for uint256;

    address user1 = makeAddr("USER1");
    address user2 = makeAddr("USER2");

    function setUp() public override {
        super.setUp();
    }

    function _deployStableVault(
        address adminParam,
        uint256,
        /* maxPerSecondRate */
        uint256 defaultSubVaultPerSecondRate,
        address iouToken,
        address fundsHandler,
        address assetRegistry,
        address transferHelper,
        address withdrawalFeeCalculator,
        address priceOracle,
        uint256 maxActiveSubVaults,
        address treasuryAddress
    ) internal virtual override returns (StableVault) {
        // Deploy a vault without restriction in the valid per-second rate
        address vaultImpl = address(
            new StableVault(
                type(uint256).max,
                assetRegistry,
                iouToken,
                fundsHandler,
                transferHelper,
                withdrawalFeeCalculator,
                priceOracle,
                maxActiveSubVaults
            )
        );
        return StableVault(
            address(
                new TransparentUpgradeableProxy(
                    address(vaultImpl),
                    proxyAdmin,
                    abi.encodeCall(
                        StableVault.initialize,
                        (adminParam, treasuryAddress, defaultSubVaultPerSecondRate, "Aave USD Stable Vault", "ASV-USD")
                    )
                )
            )
        );
    }

    function test_givenSingleAssetDepegs_userCanStillWithdraw() public {
        Logger.log("\nAccountingChainDistrustedAssetE2ETest: givenSingleAssetDepegs_userCanStillWithdraw");

        uint256 userInitialDeposit = 500 * (10 ** 6);

        // Set the default rate on Stable Vault to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToStableVault(user1, userInitialDeposit);

        // Funds land idle on the Allocator; route them into the strategy.
        address defaultUsdcVault_AccountingChain = allocator_accountingChain.getStrategiesForAsset(address(USDC))[0];
        _routeIdleToStrategy(
            allocator_accountingChain, address(USDC), defaultUsdcVault_AccountingChain, userInitialDeposit
        );
        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain),
            userInitialDeposit,
            "Default USDC strategy vault should have the deposited amount of USDC"
        );
        assertEq(
            fundsHandler.getAggregatedBalance(),
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "Funds handler should have the deposited amount of USDC"
        );

        // Assume the asset is depegged, so mark it as distrusted
        vm.prank(everyRoleAccount);
        assetRegistry_accountingChain.distrustAsset(address(USDC));

        uint256 systemBalanceAfterDistrust = vault.getAggregatedBalance();
        assertEq(systemBalanceAfterDistrust, 0, "System balance should be zero after distrusting asset");

        // User should still be able to withdraw their funds up to the original deposit amount
        vm.warp(block.timestamp + 365 days);

        uint256 systemBalanceAfterDistrustAfterYear = vault.getAggregatedBalance();
        assertEq(
            systemBalanceAfterDistrustAfterYear, 0, "System balance should be zero after a year after distrusting asset"
        );

        uint256 userBalanceAfterYear = vault.getUserBalance(user1);

        // Epect revert because system balance is zero
        vm.expectRevert(
            abi.encodeWithSelector(
                IStableVault.InsufficientAssets.selector,
                user1,
                userBalanceAfterYear,
                userInitialDeposit.assetDecimalsToRay(address(USDC))
            )
        );
        vm.prank(user1);
        vault.requestWithdrawal(user1, 0);

        // Attempt to request a withdrawal for original deposit amount + interest
        uint256 originalDepositAmountInRay = userInitialDeposit.assetDecimalsToRay(address(USDC));
        vm.prank(user1);
        vault.requestWithdrawal(user1, originalDepositAmountInRay);
        // User should still have a balance compromised of interest after requesting withdrawal of original deposit
        assertGt(
            vault.getUserBalance(user1), 0, "User balance should be zero after withdrawing original deposit amount"
        );

        // Check the users USDC balance before the withdrawal
        assertEq(IERC20(address(USDC)).balanceOf(user1), 0, "User should not have any USDC before executing withdrawal");

        // Execute the withdrawal
        vm.prank(user1);
        vault.executeWithdrawal(user1, address(USDC), 0, originalDepositAmountInRay, "");

        // Check the users USDC balance after the withdrawal
        assertEq(
            IERC20(address(USDC)).balanceOf(user1),
            userInitialDeposit,
            "User should have the deposited amount of USDC after executing withdrawal"
        );
    }

    function test_givenMultipleUsersDeposit_lastUserToWithdrawHasToWithdrawDepegedAsset() public {
        Logger.log(
            "\nAccountingChainDistrustedAssetE2ETest: givenMultipleUsersDeposit_lastUserToWithdrawHasToWithdrawDepegedAsset"
        );

        uint256 user1InitialDeposit = 500 * (10 ** 6);
        uint256 user2InitialDeposit = 123 * (10 ** 18);

        // Set the default rate on Stable Vault to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToStableVault(user1, user1InitialDeposit);
        // User2 deposits 500 GHO to Vault on Accounting Chain
        _mintAndDepositGhoToStableVault(user2, user2InitialDeposit);

        // Funds land idle on the Allocator; route both assets into their default strategies.
        address defaultUsdcVault_AccountingChain = allocator_accountingChain.getStrategiesForAsset(address(USDC))[0];
        address defaultGhoVault_AccountingChain = allocator_accountingChain.getStrategiesForAsset(address(GHO))[0];
        _routeIdleToStrategy(
            allocator_accountingChain, address(USDC), defaultUsdcVault_AccountingChain, user1InitialDeposit
        );
        _routeIdleToStrategy(
            allocator_accountingChain, address(GHO), defaultGhoVault_AccountingChain, user2InitialDeposit
        );

        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain),
            user1InitialDeposit,
            "Default USDC strategy vault should have the deposited amount of USDC"
        );
        assertEq(
            IERC20(address(GHO)).balanceOf(defaultGhoVault_AccountingChain),
            user2InitialDeposit,
            "Default GHO strategy vault should have the deposited amount of GHO"
        );
        assertEq(
            fundsHandler.getAggregatedBalance(),
            user1InitialDeposit.assetDecimalsToRay(address(USDC))
                + user2InitialDeposit.assetDecimalsToRay(address(GHO)),
            "Funds handler should have the deposited amount of USDC and GHO"
        );

        // Assume the asset is depegged, so mark it as distrusted
        vm.prank(everyRoleAccount);
        assetRegistry_accountingChain.distrustAsset(address(USDC));

        uint256 systemBalanceAfterDistrust = vault.getAggregatedBalance();
        assertEq(
            systemBalanceAfterDistrust,
            user2InitialDeposit.assetDecimalsToRay(address(GHO)),
            "System balance should be comprised of the GHO balance after distrusting USDC"
        );

        // User1 deposited 500 USDC, but they will withdraw all 123 GHO in the system
        vm.prank(user1);
        vault.requestWithdrawal(user1, 0);
        uint256 ghoOriginalDepositInRay = user2InitialDeposit.assetDecimalsToRay(address(GHO));
        vm.prank(user1);
        vault.executeWithdrawal(user1, address(GHO), 0, ghoOriginalDepositInRay, "");

        // User2 deposited 123 GHO, but since user1 withdrew it all user2 is left to withdraw USDC
        vm.prank(user2);
        vault.requestWithdrawal(user2, 0);
        // Try executing to withdraw GHO and expect revert
        vm.expectRevert(Errors.InsufficientFunds.selector);
        vm.prank(user2);
        vault.executeWithdrawal(user2, address(GHO), 0, ghoOriginalDepositInRay, "");
        // Try executing to withdraw 123 USDC and expect success
        uint256 user2OriginalDepositInRay = user2InitialDeposit.assetDecimalsToRay(address(GHO));
        vm.prank(user2);
        vault.executeWithdrawal(user2, address(USDC), 0, user2OriginalDepositInRay, "");

        // The Allocator should have 0 GHO and 500-123 USDC left
        assertEq(allocator_accountingChain.getAssetBalance(address(GHO)), 0);
        assertEq(allocator_accountingChain.getTrustedAssetBalance(address(GHO)), 0);
        assertEq(allocator_accountingChain.getAssetBalance(address(USDC)), 377 * (10 ** 6));
        // getTrustedAssetBalance should return 0 since USDC is distrusted
        assertEq(allocator_accountingChain.getTrustedAssetBalance(address(USDC)), 0);
        // The system's aggregate balance should be 0
        assertEq(vault.getAggregatedBalance(), 0);
    }

    function test_givenProfitsFromDistrustedAsset_claimSurplusInterestFails() public {
        Logger.log("\nAccountingChainDistrustedAssetE2ETest: givenProfitsFromDistrustedAsset_claimSurplusInterestFails");

        uint256 userInitialDeposit = 500 * (10 ** 6);

        // Set the default rate on Stable Vault to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToStableVault(user1, userInitialDeposit);

        // Funds land idle on the Allocator; route them into the strategy.
        address defaultUsdcVault_AccountingChain = allocator_accountingChain.getStrategiesForAsset(address(USDC))[0];
        _routeIdleToStrategy(
            allocator_accountingChain, address(USDC), defaultUsdcVault_AccountingChain, userInitialDeposit
        );
        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain),
            userInitialDeposit,
            "Default USDC strategy vault should have the deposited amount of USDC"
        );
        assertEq(
            fundsHandler.getAggregatedBalance(),
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "Funds handler should have the deposited amount of USDC"
        );

        // User should still be able to withdraw their funds up to the original deposit amount
        vm.warp(block.timestamp + 365 days);

        uint256 vaultObligations = vault.getVaultObligations();
        uint256 vaultAssets = vault.getAggregatedBalance();
        assertGt(vaultObligations, vaultAssets, "Vault obligations should be greater than vault assets");
        uint256 amountUntilProfits = vaultObligations - vaultAssets;
        uint256 profits = 100 * (10 ** 6);

        // Mint the profits to the allocator
        USDC.mint(address(allocator_accountingChain), amountUntilProfits.rayToAssetDecimals(address(USDC)) + profits);

        // Now assume the asset is depegged, so mark it as distrusted
        vm.prank(everyRoleAccount);
        assetRegistry_accountingChain.distrustAsset(address(USDC));

        uint256 systemBalanceAfterDistrust = vault.getAggregatedBalance();
        assertEq(systemBalanceAfterDistrust, 0, "System balance should be zero after distrusting asset");

        // Try to claim fees and expect revert
        address[] memory assets = new address[](1);
        assets[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = profits;

        vm.expectRevert(IStableVault.SurplusInterestClaimLeadsToInsolvency.selector);
        vm.prank(everyRoleAccount);
        vault.claimSurplusInterest(assets, amounts);
    }

    function test_givenDonationOfDistrustedAsset_userAttemptToWithdrawProfitsFails() public {
        Logger.log(
            "\nAccountingChainDistrustedAssetE2ETest: givenDonationOfDistrustedAsset_userAttemptToWithdrawProfitsFails"
        );

        uint256 user1InitialDeposit = 500 * (10 ** 6);
        uint256 user2InitialDeposit = 123 * (10 ** 18);

        // Set the default rate on Stable Vault to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToStableVault(user1, user1InitialDeposit);
        // User2 deposits 500 GHO to Vault on Accounting Chain
        _mintAndDepositGhoToStableVault(user2, user2InitialDeposit);

        // Funds land idle on the Allocator; route both assets into their default strategies.
        address defaultUsdcVault_AccountingChain = allocator_accountingChain.getStrategiesForAsset(address(USDC))[0];
        address defaultGhoVault_AccountingChain = allocator_accountingChain.getStrategiesForAsset(address(GHO))[0];
        _routeIdleToStrategy(
            allocator_accountingChain, address(USDC), defaultUsdcVault_AccountingChain, user1InitialDeposit
        );
        _routeIdleToStrategy(
            allocator_accountingChain, address(GHO), defaultGhoVault_AccountingChain, user2InitialDeposit
        );

        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain),
            user1InitialDeposit,
            "Default USDC strategy vault should have the deposited amount of USDC"
        );
        assertEq(
            IERC20(address(GHO)).balanceOf(defaultGhoVault_AccountingChain),
            user2InitialDeposit,
            "Default GHO strategy vault should have the deposited amount of GHO"
        );
        assertEq(
            fundsHandler.getAggregatedBalance(),
            user1InitialDeposit.assetDecimalsToRay(address(USDC))
                + user2InitialDeposit.assetDecimalsToRay(address(GHO)),
            "Funds handler should have the deposited amount of USDC and GHO"
        );

        // Assume the asset is depegged, so mark it as distrusted
        vm.prank(everyRoleAccount);
        assetRegistry_accountingChain.distrustAsset(address(GHO));

        // User2 donates GHO to try withdrawing more than the original deposit
        GHO.mint(user1, user1InitialDeposit);
        vm.prank(user1);

        bool success = GHO.transfer(address(vault), user1InitialDeposit);
        assertTrue(success, "Donation transfer should succeed");

        // User2 donated 123 GHO, so they will try to withdraw more than 123 USDC
        vm.warp(block.timestamp + 365 days);
        uint256 user2BalanceAfterYear = vault.getUserBalance(user2);
        assertGt(
            user2BalanceAfterYear,
            user2InitialDeposit.assetDecimalsToRay(address(GHO)),
            "User2 should have more than the original deposit"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IStableVault.InsufficientAssets.selector,
                user2,
                user2BalanceAfterYear,
                user2InitialDeposit.assetDecimalsToRay(address(GHO))
            )
        );
        vm.prank(user2);
        vault.requestWithdrawal(user2, 0);

        // Request a withdrawal for the original deposit
        uint256 user2OriginalDepositInRay = user2InitialDeposit.assetDecimalsToRay(address(GHO));
        vm.prank(user2);
        vault.requestWithdrawal(user2, user2OriginalDepositInRay);
        // Execute the withdrawal
        vm.prank(user2);
        vault.executeWithdrawal(user2, address(GHO), 0, user2OriginalDepositInRay, "");
    }

    function _mintAndDepositUsdcToStableVault(address user, uint256 amount) internal {
        USDC.mint(user, amount);
        vm.startPrank(user);
        USDC.approve(address(vault), amount);
        vault.deposit(user, address(USDC), amount);
        vm.stopPrank();
    }

    function _mintAndDepositGhoToStableVault(address user, uint256 amount) internal {
        GHO.mint(user, amount);
        vm.startPrank(user);
        GHO.approve(address(vault), amount);
        vault.deposit(user, address(GHO), amount);
        vm.stopPrank();
    }
}
