// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ExtendedBasedBoostedVault} from "./mocks/ExtendedBasedBoostedVault.sol";
import {TestErc4626} from "./mocks/TestErc4626.sol";
import {TestErc20} from "./mocks/TestErc20.sol";
import {MathLib} from "./../src/libraries/MathLib.sol";
import {AssetLib} from "./../src/libraries/AssetLib.sol";
import {FundsHandler} from "./../src/accounting-chain/FundsHandler.sol";
import {Allocator} from "./../src/accounting-chain/Allocator.sol";
import {Swapper} from "./../src/accounting-chain/Swapper.sol";
import {IBasedBoostedVault} from "./../src/accounting-chain/interfaces/IBasedBoostedVault.sol";

contract ExtendedBasedBoostedVaultT is Test {
    using MathLib for uint256;
    using AssetLib for uint256;

    address owner = address(this);
    uint256 initialBasePerSecondRate = 1e27; // 1 RAY
    ExtendedBasedBoostedVault vault;
    FundsHandler fundsHandler;
    Allocator allocator;

    TestErc20 asset;
    TestErc4626 asset4626;
    Swapper swapper;

    function setUp() public {
        console.log("Creating asset");
        asset = new TestErc20(18);
        asset4626 = new TestErc4626(asset);
        console.log("Creating vault");
        vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        allocator = new Allocator({manager: address(this), admin: address(this)});
        swapper = new Swapper(address(allocator));

        vault.updateAssetSupport(address(asset), true);
        // TODO: set communicationHandler
        fundsHandler = new FundsHandler(address(this), address(vault), address(0), address(allocator));
        vault.setFundsHandler(address(fundsHandler));

        address lockDepositor = makeAddr("lockDepositor");
        uint256 amount = 1;
        vm.startPrank(lockDepositor);
        asset.mint(lockDepositor, amount);
        asset.approve(address(vault), amount);
        vault.deposit(lockDepositor, address(asset), amount);
        vm.stopPrank();
    }

    function testMathLibRayMulDown() public pure {
        uint256 a = 19944;
        uint256 b = 1000035077411893278326216870;
        uint256 result = a.rayMulDown(b);
        assertEq(result, 19944);
    }

    function test_success_changeSubVaultRate() public {
        IBasedBoostedVault.SubVaultData[] memory activeSubVaults = vault.getActiveSubVaults();
        assertEq(activeSubVaults.length, 1);

        uint256 newPerSecondRate = 1000000001471536429740616381;
        vault.changeSubVaultRate(activeSubVaults[0].id, newPerSecondRate);

        // Assert
        IBasedBoostedVault.SubVaultData[] memory activeSubVaultsAfterUpdate = vault.getActiveSubVaults();
        assertEq(activeSubVaultsAfterUpdate.length, 1);
        assertEq(activeSubVaults[0].id, activeSubVaultsAfterUpdate[0].id);
        assertEq(activeSubVaultsAfterUpdate[0].perSecondRate, newPerSecondRate);
    }

    function testBaseConversionRateAccrualOverTime() public {
        // Arrange
        uint256 newBasePerSecondRate = 1000000001471536429740616381; // ~4.75% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        // Initial conversion rate should be RAY
        uint256 initialConversionRate = vault.getDefaultConversionRate();
        assertEq(initialConversionRate, 1e27, "Initial conversion rate should be RAY");
        console.log("Conversion rate year 0:", initialConversionRate);
        assertEq(vault.getBaseApr(), 46406372848300078191216000);

        // Move time forward by 1 year
        uint256 secondsInYear = 365 days;
        vm.warp(block.timestamp + secondsInYear);
        vault.forceAccrueSubVaultConversionRate();

        // Assert: conversion rate should have grown by ~5%
        uint256 newConversionRateYear1 = vault.getDefaultConversionRate();
        console.log("Conversion rate year 1:", newConversionRateYear1);
        assertGt(newConversionRateYear1, initialConversionRate);

        // The rate should not be different from 1 year prior
        assertEq(vault.getBaseApr(), 46406372848300078191216000);

        vm.warp(block.timestamp + secondsInYear);
        vault.forceAccrueSubVaultConversionRate();

        // Assert: conversion rate should have grown by ~5%
        uint256 newConversionRateYear2 = vault.getDefaultConversionRate();
        console.log("Conversion rate year 2:", newConversionRateYear2);
        assertGt(newConversionRateYear2, newConversionRateYear1);
        assertGt(newConversionRateYear2 - 1e27, 2 * (newConversionRateYear1 - 1e27));
    }

    function testBoostedRateAgainstExpectedConstantAPY_100K() public {
        // In a way (18 decimal number), 1e14 means the error is in the 5th decimal place, so < 0.0001
        uint256 acceptedDelta = 1e14;

        // Compare contract 4% base APY + boost to 5% APY against plain direct pure math with 5% APY
        uint256 expectedApyPerSecondRate = 1000000001547125957863212449; // 5% APY equivalent per-second rate

        // Arrange
        uint256 newBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        // Asset deposit
        uint256 amount = 100_000 ether;
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(address(this), address(asset), amount);
        uint256 amountInRay = amount.assetDecimalsToRay(address(asset));

        vault.setUserRate(address(this), expectedApyPerSecondRate); // Boost from ~4% to ~5% APY

        console.log("After 1 year...");
        vm.warp(block.timestamp + 365 days);
        uint256 expectedBalance = amountInRay.mulByRay(expectedApyPerSecondRate.rpow(365 days));
        console.log("Expected Balance:", expectedBalance);
        uint256 actualBalance = vault.getUserBalance(address(this));
        console.log("Actual Balance:", actualBalance);
        uint256 delta = expectedBalance - actualBalance;
        console.log("Actual Balance after year 1:", actualBalance);
        console.log("Expected Balance:", expectedBalance);
        console.log("Delta:", delta);
        assertLt(delta, acceptedDelta);

        console.log("After 2 years...");
        vm.warp(block.timestamp + 365 days);
        expectedBalance = amountInRay.mulByRay(expectedApyPerSecondRate.rpow(2 * 365 days));
        actualBalance = vault.getUserBalance(address(this));
        delta = expectedBalance - actualBalance;
        console.log("Actual Balance after year 2:", actualBalance);
        console.log("Expected Balance:", expectedBalance);
        console.log("Delta:", delta);
        assertLt(delta, acceptedDelta);

        console.log("After 10 years...");
        vm.warp(block.timestamp + 365 days * 8);
        expectedBalance = amountInRay.mulByRay(expectedApyPerSecondRate.rpow(10 * 365 days));
        actualBalance = vault.getUserBalance(address(this));
        delta = expectedBalance - actualBalance;
        console.log("Actual Balance after year 10:", actualBalance);
        console.log("Expected Balance:", expectedBalance);
        console.log("Delta:", delta);
        assertLt(delta, acceptedDelta);
    }

    function testBoostedRateAgainstExpectedConstantAPY_2Billion() public {
        /* Context: check that the delta b/w expected and actual is ~$1 if $2b deposited for 10 years;
         *          expected assumes 5% APY base rate, actual assumes 4% APY base rate & 1% APY boost
         * Deposit at t0:                 100,000.000000000000000000
         * t0 + 10yr @ 4% + 1% boost APY: 162,889.462628316098542802
         * t0 + 10yr @ 5% APY:            162,889.462677744140615978
         * Delta after year 10:                 0.000049428042073176
         * 2,000,000,000 after 10 years = ~$1 delta
         */

        // Compare contract 4% base APY + boost to 5% APY against plain direct pure math with 5% APY
        uint256 expectedApyPerSecondRate = 1000000001547125957863212449; // 5% APY equivalent per-second rate

        // Arrange
        uint256 newBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        // Asset deposit
        uint256 amount = 2_000_000_000 ether;
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(address(this), address(asset), amount);
        uint256 amountInRay = amount.assetDecimalsToRay(address(asset));

        vault.setUserRate(address(this), expectedApyPerSecondRate);

        console.log("After 1 year...");
        vm.warp(block.timestamp + 365 days);
        uint256 expectedBalance = amountInRay.mulByRay(expectedApyPerSecondRate.rpow(365 days));
        uint256 actualBalance = vault.getUserBalance(address(this));
        uint256 delta = expectedBalance - actualBalance;
        console.log("Actual Balance after year 1:", actualBalance);
        console.log("Expected Balance:", expectedBalance);
        console.log("Delta:", delta);

        console.log("After 2 years...");
        vm.warp(block.timestamp + 365 days);
        expectedBalance = amountInRay.mulByRay(expectedApyPerSecondRate.rpow(2 * 365 days));
        actualBalance = vault.getUserBalance(address(this));
        delta = expectedBalance - actualBalance;
        console.log("Actual Balance after year 2:", actualBalance);
        console.log("Expected Balance:", expectedBalance);
        console.log("Delta:", delta);

        console.log("After 10 years...");
        vm.warp(block.timestamp + 365 days * 8);
        expectedBalance = amountInRay.mulByRay(expectedApyPerSecondRate.rpow(10 * 365 days));
        actualBalance = vault.getUserBalance(address(this));
        delta = expectedBalance - actualBalance;
        console.log("Actual Balance after year 10:", actualBalance);
        console.log("Expected Balance:", expectedBalance);
        console.log("Delta:", delta);
        assertLt(delta, 1e18);
    }

    function testSameBlockDepositAndWithdrawMax(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000_000_000 ether);

        uint256 blockTimestamp = block.timestamp;

        uint256 newBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        address account1 = makeAddr("account1");
        vm.prank(account1);
        asset.mint(account1, amount);
        vm.prank(account1);
        asset.approve(address(vault), amount);
        vm.prank(account1);
        vault.deposit(account1, address(asset), amount);

        uint256 assetBalance = vault.getUserBalance(account1).rayToAssetDecimals(address(asset));
        assertEq(assetBalance, amount, "Asset balance does not match initial deposited amount");

        // Without advancing the block or timestamp, call full withdrawal
        vm.prank(account1);
        uint256 withdrawalRequestId = vault.requestWithdrawal(account1, address(asset), 0);
        (uint256 assetsWithdrawn,) = vault.executeWithdrawal(withdrawalRequestId, "");

        uint256 assetBalanceAfterWithdraw = vault.getUserBalance(account1);

        assertEq(assetBalance, assetsWithdrawn, "Asset balance does not match withdrawn amount");
        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");

        assertEq(block.timestamp, blockTimestamp, "Final block timestamp does not match initial timestamp");
    }

    function testMultiBlockDepositAndWithdrawMax_simple(uint256 amount, uint256 elapsedTime) public {
        //uint256 maxYearsThatCanBeElapsed = 1_354; // Estimate of the absolute maximum number of years that can be elapsed before arithmatic overflow due to RAY mul
        uint256 maxYearsThatCanBeElapsed = 645;
        amount = bound(amount, 1, 1_000_000_000_000 ether);
        elapsedTime = bound(elapsedTime, 0, 365 days * maxYearsThatCanBeElapsed);

        uint256 blockTimestamp = block.timestamp;

        uint256 newBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        address account1 = makeAddr("account1");
        vm.prank(account1);
        asset.mint(account1, amount);
        vm.prank(account1);
        asset.approve(address(vault), amount);
        vm.prank(account1);
        vault.deposit(account1, address(asset), amount);

        uint256 assetBalance = vault.getUserBalance(account1).rayToAssetDecimals(address(asset));
        // Check
        assertGe(assetBalance, amount - 1, "Asset balance too low compared to initial deposited amount");
        assertLe(assetBalance, amount, "Asset balance too high compared to initial deposited amount");

        // Withdraw after advancing block some time
        vm.warp(blockTimestamp + elapsedTime);

        assetBalance = vault.getUserBalance(account1).rayToAssetDecimals(address(asset));

        uint256 assetsEarned = assetBalance - amount;
        asset.mint(address(fundsHandler), assetsEarned); // TODO: Replace with adding into float

        vm.prank(account1);
        uint256 withdrawalRequestId = vault.requestWithdrawal(account1, address(asset), 0);
        (uint256 assetsWithdrawn,) = vault.executeWithdrawal(withdrawalRequestId, "");

        uint256 assetBalanceAfterWithdraw = vault.getUserBalance(account1);

        assertEq(assetBalance, assetsWithdrawn, "Asset balance does not match withdrawn amount");
        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");
    }

    function testOneUnitDepositSameBlock(uint256 previousDepositAmount) public {
        previousDepositAmount = bound(previousDepositAmount, 0, 1_000_000_000_000 ether);

        uint256 blockTimestamp = block.timestamp;

        uint256 newBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        address account1 = makeAddr("account1");
        if (previousDepositAmount > 0) {
            vm.prank(account1);
            asset.mint(account1, previousDepositAmount);
            vm.prank(account1);
            asset.approve(address(vault), previousDepositAmount);
            vm.prank(account1);
            vault.deposit(account1, address(asset), previousDepositAmount);
        }

        uint256 initialAssetBalance = vault.getUserBalance(account1).rayToAssetDecimals(address(asset));
        assertEq(initialAssetBalance, previousDepositAmount, "Asset balance does not match initial deposited amount");

        vm.prank(account1);
        asset.mint(account1, 1);
        vm.prank(account1);
        asset.approve(address(vault), 1);
        vm.prank(account1);
        vault.deposit(account1, address(asset), 1);

        // Without advancing the block or timestamp, call full withdrawal
        vm.prank(account1);
        uint256 withdrawalRequestId = vault.requestWithdrawal(account1, address(asset), 0);
        (uint256 assetsWithdrawn,) = vault.executeWithdrawal(withdrawalRequestId, "");

        uint256 assetBalanceAfterWithdraw = vault.getUserBalance(account1);

        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");
        assertEq(
            assetsWithdrawn, initialAssetBalance + 1, "Assets withdrawn does not take into account the 1 unit deposit"
        );

        assertEq(block.timestamp, blockTimestamp, "Final block timestamp does not match initial timestamp");
    }

    function testMultiBlockDepositAndWithdrawMax_largeApy(uint256 amount, uint256 elapsedTime) public {
        // 1000000000377783247012652819 ~= 10% APY
        //uint256 maxYearsThatCanBeElapsed = 1_354; // Estimate of the absolute maximum number of years that can be elapsed before arithmatic overflow due to RAY mul
        uint256 maxYearsThatCanBeElapsed = 645;
        amount = bound(amount, 1, 1_000_000_000_000 ether);
        elapsedTime = bound(elapsedTime, 0, 365 days * maxYearsThatCanBeElapsed);

        uint256 blockTimestamp = block.timestamp;

        uint256 newBasePerSecondRate = 1000000000377783247012652819;
        _setDefaultPerSecondRate(newBasePerSecondRate);

        address account1 = makeAddr("account1");
        vm.prank(account1);
        asset.mint(account1, amount);
        vm.prank(account1);
        asset.approve(address(vault), amount);
        vm.prank(account1);
        vault.deposit(account1, address(asset), amount);

        uint256 assetBalance = vault.getUserBalance(account1).rayToAssetDecimals(address(asset));
        assertGe(assetBalance, amount - 1, "Asset balance too low compared to initial deposited amount");
        assertLe(assetBalance, amount, "Asset balance too high compared to initial deposited amount");

        // Withdraw after advancing block some time
        vm.warp(blockTimestamp + elapsedTime);

        assetBalance = vault.getUserBalance(account1).rayToAssetDecimals(address(asset));

        uint256 assetsEarned = assetBalance - amount;
        asset.mint(address(fundsHandler), assetsEarned);

        vm.prank(account1);
        uint256 withdrawalRequestId = vault.requestWithdrawal(account1, address(asset), 0);
        (uint256 assetsWithdrawn,) = vault.executeWithdrawal(withdrawalRequestId, "");

        uint256 assetBalanceAfterWithdraw = vault.getUserBalance(account1);

        assertEq(assetBalance, assetsWithdrawn, "Asset balance does not match withdrawn amount");
        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");
    }

    function testMultiBlockDepositAndWithdrawMax_multiAccount(uint256 amount, uint256 elapsedTime) public {
        // 1000000000377783247012652819 ~= 10% APY
        uint256 maxYearsThatCanBeElapsed = 100;
        amount = bound(amount, 1, 1_000_000_000_000 ether);
        elapsedTime = bound(elapsedTime, 0, 365 days * maxYearsThatCanBeElapsed);

        uint256 newBasePerSecondRate = 1000000000377783247012652819;
        _setDefaultPerSecondRate(newBasePerSecondRate);

        address account2 = makeAddr("account2");
        vm.prank(account2);
        asset.mint(account2, amount);
        vm.prank(account2);
        asset.approve(address(vault), amount);
        vm.prank(account2);
        vault.deposit(account2, address(asset), amount);
        uint256 assetBalanceAcct2 = vault.getUserBalance(account2).rayToAssetDecimals(address(asset));
        assertGe(
            assetBalanceAcct2, amount - 1, "Asset balance too low compared to initial deposited amount for account2"
        );
        assertLe(assetBalanceAcct2, amount, "Asset balance too high compared to initial deposited amount for account2");

        vm.warp(block.timestamp + 1 days);

        address account1 = makeAddr("account1");
        vm.prank(account1);
        asset.mint(account1, amount);
        vm.prank(account1);
        asset.approve(address(vault), amount);
        vm.prank(account1);
        vault.deposit(account1, address(asset), amount);

        uint256 assetBalanceAcct1 = vault.getUserBalance(account1).rayToAssetDecimals(address(asset));

        assertGe(
            assetBalanceAcct1, amount - 1, "Asset balance too low compared to initial deposited amount for account1"
        );
        assertLe(assetBalanceAcct1, amount, "Asset balance too high compared to initial deposited amount for account1");

        // Withdraw after advancing block some time
        vm.warp(block.timestamp + elapsedTime);
        assetBalanceAcct1 = vault.getUserBalance(account1).rayToAssetDecimals(address(asset));
        // Since balance is rounding down then withdrawing max will fail because shares will be 0
        vm.assume(assetBalanceAcct1 > 1);

        uint256 assetsEarned = assetBalanceAcct1 > amount ? assetBalanceAcct1 - amount : 0;
        if (assetsEarned > 0) {
            asset.mint(address(fundsHandler), assetsEarned);
        }

        vm.prank(account1);
        uint256 withdrawalRequestId = vault.requestWithdrawal(account1, address(asset), 0);
        (uint256 assetsWithdrawn,) = vault.executeWithdrawal(withdrawalRequestId, "");

        console.log("block timestamp after withdraw:", block.timestamp);
        uint256 assetBalanceAfterWithdraw = vault.getUserBalance(account1);

        assertEq(assetBalanceAcct1, assetsWithdrawn, "Asset balance does not match withdrawn amount");
        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");
    }

    function testSetUserRatesOver10Years() public {
        // Context: - find driver of value delta between ending balance of (5% base) APY vs (4% base + 1% boost) APY
        //          - add intermittent boosts across the time period of the initial deposit made
        //          - as of the writing of this test we concluded that intermittent deposits/withdrawals were not a driver of divergence in actual vs expected at the end of the 10 years
        // WolframAlpha: 2,000,000,000 * 1.05^10 = 3,257,789,253.5548828125
        uint256 originalDeposit = 2_000_000_000 ether;

        uint256 newBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        // Asset deposit
        TestErc20 testAsset = new TestErc20(18);
        vault.updateAssetSupport(address(testAsset), true);
        testAsset.mint(address(this), originalDeposit);
        testAsset.approve(address(vault), originalDeposit);
        vault.deposit(address(this), address(testAsset), originalDeposit);

        testAsset.approve(address(vault), originalDeposit);

        uint256 boost4To5 = 1000000000303445301167003084;

        // Set initial boost to set effective rate from 4% APY to 5% APY
        vault.setUserRate(address(this), boost4To5);

        uint256 currentBlockTs = block.timestamp;
        uint256 numberOfYears = 10;
        uint256 endingBlockTs = currentBlockTs + (365 days * numberOfYears);
        uint256 numberOfBoostsPerYear = 100;
        uint256 totalBoosts = numberOfBoostsPerYear * numberOfYears;
        uint256 interval = (endingBlockTs - currentBlockTs) / totalBoosts;

        bool addOneToBoost = true;
        for (uint256 i = 0; i < totalBoosts; i++) {
            uint256 nextTs = currentBlockTs + (i + 1) * interval;
            vm.warp(nextTs);
            vault.setUserRate(address(this), boost4To5 + (addOneToBoost ? 1 : 0));
            addOneToBoost = !addOneToBoost;
        }

        console.log("block.timestamp: ", block.timestamp);
        console.log("endingBlockTs: ", endingBlockTs);
        assertEq(block.timestamp, endingBlockTs);

        uint256 thisUsdBalanceInVault = vault.getUserBalance(address(this)).rayToAssetDecimals(address(testAsset));
        console.log("thisUsdBalanceInVault: ", thisUsdBalanceInVault);

        uint256 expectedBalanceAfter10Years = 3_257_789_253_554882812500000000;
        console.log("delta_account_1: ", expectedBalanceAfter10Years - thisUsdBalanceInVault);
    }

    function test_success_baseRateChange() public {
        uint256 newBasePerSecondRate = 1000000003022265980097387650; // 10% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        address account1 = makeAddr("account1");

        TestErc20 testAsset = new TestErc20(18);
        vault.updateAssetSupport(address(testAsset), true);

        uint256 initialDeposit = 1_000_000 * 10 ** 18;
        uint256 initialDepositInRay = initialDeposit * 10 ** 9;
        testAsset.mint(account1, initialDeposit);
        vm.prank(account1);
        testAsset.approve(address(vault), initialDeposit);
        vm.prank(account1);
        vault.deposit(account1, address(testAsset), initialDeposit);

        // Check base rate change after 6 months
        uint256 sixMonths = 15768000;
        vm.warp(block.timestamp + sixMonths);

        uint256 balanceAfter6Months = vault.getUserBalance(account1);
        console.log("balanceAfter6Months: ", balanceAfter6Months);

        // Change the base rate to 15%
        uint256 higherBasePerSecondRate = 1000000004431822129783699001;
        _setDefaultPerSecondRate(higherBasePerSecondRate);

        vm.warp(block.timestamp + sixMonths);

        uint256 balanceAfter12Months = vault.getUserBalance(account1);

        uint256 expectedBalanceIfOriginalRateFor12Months =
            balanceAfter6Months.mulByRay(newBasePerSecondRate.rpow(sixMonths));
        assertGt(
            balanceAfter12Months,
            expectedBalanceIfOriginalRateFor12Months,
            "Expected higher balance after 12 with rate change"
        );

        uint256 expectedBalanceWithRateChangeAfter6Month = initialDepositInRay.mulByRay(
            newBasePerSecondRate.rpow(sixMonths)
        ).mulByRay(higherBasePerSecondRate.rpow(sixMonths));
        uint256 delta = expectedBalanceWithRateChangeAfter6Month - balanceAfter12Months;
        // Balances are queried in RAY, so expect at least the first 9 decimal places to be the same
        assertEq(delta / 1e18, 0, "Expected lower delta");
    }

    function test_success_baseRateChange_withBoost() public {
        uint256 newBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        uint256 expectedTotalPerSecondRate = 1000000001547125957863212449; // 5% APY

        address account1 = makeAddr("account1");

        TestErc20 testAsset = new TestErc20(18);
        vault.updateAssetSupport(address(testAsset), true);

        uint256 initialDeposit = 1_000_000 * 10 ** 18;
        uint256 initialDepositInRay = initialDeposit * 10 ** 9;
        testAsset.mint(account1, initialDeposit);
        vm.prank(account1);
        testAsset.approve(address(vault), initialDeposit);
        vm.prank(account1);
        vault.deposit(account1, address(testAsset), initialDeposit);

        vault.setUserRate(account1, expectedTotalPerSecondRate);

        // Check base rate change after 6 months
        uint256 sixMonths = 15768000;
        vm.warp(block.timestamp + sixMonths);

        uint256 balanceAfter6Months = vault.getUserBalance(account1);
        console.log("balanceAfter6Months: ", balanceAfter6Months);

        // Change the base rate to 6%
        uint256 higherBasePerSecondRate = 1000000001847694957439350563;
        _setDefaultPerSecondRate(higherBasePerSecondRate);

        uint256 expectedTotalPerSecondRateAfterChange = 1000000002145441671308778766; // 7% APY

        // Set user's sub-vault rate to 7%
        IBasedBoostedVault.SubVaultData memory userSubVault = vault.getUserSubVault(account1);
        vault.changeSubVaultRate(userSubVault.id, expectedTotalPerSecondRateAfterChange);

        vm.warp(block.timestamp + sixMonths);

        uint256 balanceAfter12Months = vault.getUserBalance(account1);
        console.log("balanceAfter12Months: ", balanceAfter12Months);

        uint256 expectedBalanceIfOriginalRateFor12Months =
            balanceAfter6Months.mulByRay(expectedTotalPerSecondRate.rpow(sixMonths));
        assertGt(
            balanceAfter12Months,
            expectedBalanceIfOriginalRateFor12Months,
            "Expected higher balance after 12 with rate change"
        );

        // Avoid stack too deep error
        uint256 expectedBalanceWithRateChangeAfter6Month0 =
            initialDepositInRay.mulByRay(expectedTotalPerSecondRate.rpow(sixMonths));
        uint256 expectedBalanceWithRateChangeAfter6Month =
            expectedBalanceWithRateChangeAfter6Month0.mulByRay(expectedTotalPerSecondRateAfterChange.rpow(sixMonths));

        uint256 delta = expectedBalanceWithRateChangeAfter6Month > balanceAfter12Months
            ? expectedBalanceWithRateChangeAfter6Month - balanceAfter12Months
            : balanceAfter12Months - expectedBalanceWithRateChangeAfter6Month;
        console.log("delta: ", delta);
        // FIXME: can we improve the delta here? The issue is the boost multiplier for extra 1% on base rate at t_0 does not translate to an extra 1% on base rate at t_1 (assuming the base rate is different)
        // Balances are queried in RAY, so expect at least the first 9 decimal places to be the same
        assertEq(delta / 1e18, 0, "Expected lower delta");
    }

    function test_success_variousDecimalPlaceTokenDeposits_simple() public {
        address account1 = makeAddr("account1");
        TestErc20 asset18dp = new TestErc20(18);
        vault.updateAssetSupport(address(asset18dp), true);
        TestErc20 asset6dp = new TestErc20(6);
        vault.updateAssetSupport(address(asset6dp), true);

        uint256 oneMillionUsd18dp = 1000000000000000000000000;
        uint256 oneMillionUsd6dp = 1000000000000;

        uint256 newBasePerSecondRate = 1000000000377783247012652819;
        _setDefaultPerSecondRate(newBasePerSecondRate);

        asset18dp.mint(account1, oneMillionUsd18dp);
        asset6dp.mint(account1, oneMillionUsd6dp);
        vm.prank(account1);
        asset6dp.approve(address(vault), oneMillionUsd6dp);
        vm.prank(account1);
        asset18dp.approve(address(vault), oneMillionUsd18dp);

        vm.prank(account1);
        vault.deposit(account1, address(asset18dp), oneMillionUsd18dp);

        // Move forward in time to check balance accrual
        vm.warp(block.timestamp + 365 days);

        uint256 accountBalance1 = vault.getUserBalance(account1);
        console.log("accountBalance1: ", accountBalance1);
        vm.prank(account1);
        vault.deposit(account1, address(asset6dp), oneMillionUsd6dp);
        // Check balance after depositing 6dp token
        uint256 accountBalance2 = vault.getUserBalance(account1);
        console.log("accountBalance2: ", accountBalance2);

        // Conversion from shares to obtain accountBalance2 rounds down.
        // Since this check is in the same block as the deposit, we lose 1 unit of RAY.
        assertEq(accountBalance2 + 1, accountBalance1 + oneMillionUsd6dp * 10 ** (27 - 6));
    }

    function test_success_variousDecimalPlaceTokenDeposits_withBoost() public {
        address account1 = makeAddr("account1");
        TestErc20 asset18dp = new TestErc20(18);
        vault.updateAssetSupport(address(asset18dp), true);
        TestErc20 asset6dp = new TestErc20(6);
        vault.updateAssetSupport(address(asset6dp), true);

        uint256 oneMillionUsd18dp = 1000000000000000000000000;
        uint256 oneMillionUsd6dp = 1000000000000;

        uint256 expectedApyPerSecondRate = 1000000001547125957863212449; // 5% APY equivalent per-second rate

        uint256 newBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        _setDefaultPerSecondRate(newBasePerSecondRate);

        asset18dp.mint(account1, oneMillionUsd18dp);
        asset6dp.mint(account1, oneMillionUsd6dp);
        vm.prank(account1);
        asset6dp.approve(address(vault), oneMillionUsd6dp);
        vm.prank(account1);
        asset18dp.approve(address(vault), oneMillionUsd18dp);

        // Deposit $2m in different tokens
        vm.prank(account1);
        vault.deposit(account1, address(asset18dp), oneMillionUsd18dp);
        vm.prank(account1);
        vault.deposit(account1, address(asset6dp), oneMillionUsd6dp);

        // Set boost within same block after depositing
        vault.setUserRate(account1, expectedApyPerSecondRate);

        // Move forward in time to check balance accrual
        vm.warp(block.timestamp + 365 days);
        uint256 twoMillionRay = 2_000_000 * 10 ** 27;
        uint256 expectedBalance = twoMillionRay.mulByRay(expectedApyPerSecondRate.rpow(365 days));

        // Check that account balance is within some threshold of expected balance
        // Balances are in RAY, so to convert to USD, we need to divide by 10 ** 27
        uint256 accountBalance1 = vault.getUserBalance(account1);
        uint256 delta =
            expectedBalance > accountBalance1 ? expectedBalance - accountBalance1 : accountBalance1 - expectedBalance;
        // First 9 decimal places are the same
        assertEq(delta / 10 ** 18, 0);
    }

    // -------------------------------------------------------------
    // Error Path Tests
    // -------------------------------------------------------------

    function test_revert_setUserRate_NonExistentPosition() public {
        address account1 = makeAddr("account1");
        vm.expectRevert(IBasedBoostedVault.NonExistentPosition.selector);
        vault.setUserRate(account1, 1000000000303445301167003084);
    }

    function test_revert_setUserRate_redundantRate() public {
        address account1 = makeAddr("account1");
        uint256 depositAmount = 1;
        uint256 boost4To5 = 1000000000303445301167003084;

        asset.mint(account1, depositAmount);

        vm.prank(account1);
        asset.approve(address(vault), depositAmount);
        vm.prank(account1);
        vault.deposit(account1, address(asset), depositAmount);

        vault.setUserRate(account1, boost4To5);
        vm.expectRevert(IBasedBoostedVault.RedundantRate.selector);
        vault.setUserRate(account1, boost4To5);
    }

    function test_revert_setBaseRate_invalidRate() public {
        vm.expectRevert(IBasedBoostedVault.InvalidRate.selector);
        _setDefaultPerSecondRate(12345);
    }

    function test_revert_deposit_invalidMsgSender() public {
        address account1 = makeAddr("account1");
        asset.mint(account1, 1);
        asset.approve(address(vault), 1);

        // Call deposit from different address
        vm.prank(makeAddr("account2"));
        vm.expectRevert(IBasedBoostedVault.InvalidMsgSender.selector);
        vault.deposit(account1, address(asset), 1);
    }

    function test_revert_addSupportedAsset_invalidAsset() public {
        vm.expectRevert(abi.encodeWithSelector(IBasedBoostedVault.InvalidAsset.selector, address(0)));
        vault.updateAssetSupport(address(0), true);
    }

    function test_revert_addSupportedAsset_alreadySupported() public {
        TestErc20 testAsset = new TestErc20(18);
        vault.updateAssetSupport(address(testAsset), true);
        vm.expectRevert(abi.encodeWithSelector(IBasedBoostedVault.AssetAlreadySupported.selector, address(testAsset)));
        vault.updateAssetSupport(address(testAsset), true);
    }

    function test_revert_removeSupportedAsset_invalidAsset() public {
        vm.expectRevert(abi.encodeWithSelector(IBasedBoostedVault.InvalidAsset.selector, address(0)));
        vault.updateAssetSupport(address(0), false);
    }

    function test_revert_removeSupportedAsset_notSupported() public {
        TestErc20 testAsset = new TestErc20(18);
        vm.expectRevert(abi.encodeWithSelector(IBasedBoostedVault.AssetNotSupported.selector, address(testAsset)));
        vault.updateAssetSupport(address(testAsset), false);
    }

    function test_revert_deposit_unsupportedAsset() public {
        address account1 = makeAddr("account1");
        TestErc20 testAsset = new TestErc20(18);

        testAsset.mint(account1, 1);
        vm.prank(account1);
        testAsset.approve(address(vault), 1);

        vm.expectRevert(abi.encodeWithSelector(IBasedBoostedVault.UnsupportedAsset.selector, address(testAsset)));
        vm.prank(account1);
        vault.deposit(account1, address(testAsset), 1);
    }

    function _setDefaultPerSecondRate(uint256 basePerSecondRate) public {
        // The "default" subvault that has the effective base rate will always have id 1
        vault.changeSubVaultRate(1, basePerSecondRate);
    }
}
