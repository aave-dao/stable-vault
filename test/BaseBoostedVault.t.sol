// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ExtendedBasedBoostedVault} from "./mocks/ExtendedBasedBoostedVault.sol";
import {TestErc20} from "./mocks/TestErc20.sol";
import {MathLib} from "./../src/libraries/MathLib.sol";
import {IBasedBoostedVault} from "./../src/accounting-chain/IBasedBoostedVault.sol";

contract ExtendedBasedBoostedVaultT is Test {
    using MathLib for uint256;

    function _deployVault(address owner, uint256 initialBasePerSecondRate)
        internal
        virtual
        returns (IBasedBoostedVault)
    {
        return IBasedBoostedVault(new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate));
    }

    function testMathLibRayMulDown() public pure {
        uint256 a = 19944;
        uint256 b = 1000035077411893278326216870;
        uint256 result = a.rayMulDown(b);
        assertEq(result, 19944);
    }

    function testSetBasePerSecondRate() public {
        // Arrange
        address owner = address(this);
        uint256 initialBasePerSecondRate = 1e27; // 1 RAY
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        // Act
        uint256 newBasePerSecondRate = 1000000001471536429740616381; // ~= ~4.75% APY
        vault.setBasePerSecondRate(newBasePerSecondRate);

        // Assert
        uint256 actual = vault.getBasePerSecondRate();
        assertEq(actual, newBasePerSecondRate, "Base per second rate should be updated");
        console.log("Base APR:", vault.getBaseAPR());
        assertEq(vault.getBaseAPR(), 46406372848300078191216000);
    }

    function testBaseConversionRateAccrualOverTime() public {
        // Arrange
        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000001471536429740616381; // ~4.75% APY
        //uint256 initialBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        // Initial conversion rate should be RAY
        uint256 initialConversionRate = vault.getBoostConversionRate();
        assertEq(initialConversionRate, 1e27, "Initial conversion rate should be RAY");
        console2.log("Conversion rate year 0:", initialConversionRate);
        assertEq(vault.getBaseAPR(), 46406372848300078191216000);

        // Move time forward by 1 year
        uint256 secondsInYear = 365 days;
        vm.warp(block.timestamp + secondsInYear);
        vault.forceAccrueBaseConversionRate();

        // Assert: conversion rate should have grown by ~5%
        uint256 newConversionRateYear1 = vault.getBoostConversionRate();
        console2.log("Conversion rate year 1:", newConversionRateYear1);
        assertGt(newConversionRateYear1, initialConversionRate);

        // The rate should not be different from 1 year prior
        assertEq(vault.getBaseAPR(), 46406372848300078191216000);

        vm.warp(block.timestamp + secondsInYear);
        vault.forceAccrueBaseConversionRate();

        // Assert: conversion rate should have grown by ~5%
        uint256 newConversionRateYear2 = vault.getBoostConversionRate();
        console2.log("Conversion rate year 2:", newConversionRateYear2);
        assertGt(newConversionRateYear2, newConversionRateYear1);
        assertGt(newConversionRateYear2 - 1e27, 2 * (newConversionRateYear1 - 1e27));
    }

    function testBoostedRateAgainstExpectedConstantAPY() public {
        // In a way (18 decimal number), 1e14 means the error is in the 5th decimal place, so < 0.0001
        uint256 acceptedDelta = 1e14;

        // Compare contract 4% base APY + boost to 5% APY against plain direct pure math with 5% APY
        uint256 expectedApyPerSecondRate = 1000000001547125957863212449; // 5% APY equivalent per-second rate

        // Arrange
        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        // Asset deposit
        uint256 amount = 100_000 ether;
        TestErc20 asset = new TestErc20();
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(address(this), address(asset), amount);

        vault.setBoost(address(this), 1000000000303445301167003084); // Boost from ~4% to ~5% APY

        console2.log("After 1 year...");
        vm.warp(block.timestamp + 365 days);
        uint256 expectedBalance = amount.mulByRay(expectedApyPerSecondRate.rpow(365 days));
        uint256 actualBalance = vault.getAccountBalance(address(this));
        uint256 delta = expectedBalance - actualBalance;
        console2.log("Actual Balance after year 1:", actualBalance);
        console2.log("Expected Balance:", expectedBalance);
        console2.log("Delta:", delta);
        assertLt(delta, acceptedDelta);

        console2.log("After 2 years...");
        vm.warp(block.timestamp + 365 days);
        expectedBalance = amount.mulByRay(expectedApyPerSecondRate.rpow(2 * 365 days));
        actualBalance = vault.getAccountBalance(address(this));
        delta = expectedBalance - actualBalance;
        console2.log("Actual Balance after year 2:", actualBalance);
        console2.log("Expected Balance:", expectedBalance);
        console2.log("Delta:", delta);
        assertLt(delta, acceptedDelta);

        console2.log("After 10 years...");
        vm.warp(block.timestamp + 365 days * 8);
        expectedBalance = amount.mulByRay(expectedApyPerSecondRate.rpow(10 * 365 days));
        actualBalance = vault.getAccountBalance(address(this));
        delta = expectedBalance - actualBalance;
        console2.log("Actual Balance after year 10:", actualBalance);
        console2.log("Expected Balance:", expectedBalance);
        console2.log("Delta:", delta);
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
        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        // Asset deposit
        uint256 amount = 2_000_000_000 ether;
        TestErc20 asset = new TestErc20();
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(address(this), address(asset), amount);

        vault.setBoost(address(this), 1000000000303445301167003084); // Boost from ~4% to ~5% APY

        console2.log("After 1 year...");
        vm.warp(block.timestamp + 365 days);
        uint256 expectedBalance = amount.mulByRay(expectedApyPerSecondRate.rpow(365 days));
        uint256 actualBalance = vault.getAccountBalance(address(this));
        uint256 delta = expectedBalance - actualBalance;
        console2.log("Actual Balance after year 1:", actualBalance);
        console2.log("Expected Balance:", expectedBalance);
        console2.log("Delta:", delta);

        console2.log("After 2 years...");
        vm.warp(block.timestamp + 365 days);
        expectedBalance = amount.mulByRay(expectedApyPerSecondRate.rpow(2 * 365 days));
        actualBalance = vault.getAccountBalance(address(this));
        delta = expectedBalance - actualBalance;
        console2.log("Actual Balance after year 2:", actualBalance);
        console2.log("Expected Balance:", expectedBalance);
        console2.log("Delta:", delta);

        console2.log("After 10 years...");
        vm.warp(block.timestamp + 365 days * 8);
        expectedBalance = amount.mulByRay(expectedApyPerSecondRate.rpow(10 * 365 days));
        actualBalance = vault.getAccountBalance(address(this));
        delta = expectedBalance - actualBalance;
        console2.log("Actual Balance after year 10:", actualBalance);
        console2.log("Expected Balance:", expectedBalance);
        console2.log("Delta:", delta);
        assertLt(delta, 1e18);
    }

    function testSameBlockDepositAndWithdrawMax(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000_000_000 ether);

        uint256 blockTimestamp = block.timestamp;

        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        TestErc20 asset = new TestErc20();
        address account1 = makeAddr("account1");
        vm.prank(account1);
        asset.mint(account1, amount);
        vm.prank(account1);
        asset.approve(address(vault), amount);
        vm.prank(account1);
        vault.deposit(account1, address(asset), amount);

        uint256 assetBalance = vault.getAccountBalance(account1);
        assertEq(assetBalance, amount, "Asset balance does not match initial deposited amount");

        // Without advancing the block or timestamp, call full withdrawal
        vm.prank(account1);
        uint256 assetsWithdrawn = vault.withdraw(account1, address(asset), assetBalance);

        uint256 assetBalanceAfterWithdraw = vault.getAccountBalance(account1);

        assertEq(assetBalance, assetsWithdrawn, "Asset balance does not match withdrawn amount");
        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");

        assertEq(block.timestamp, blockTimestamp, "Final block timestamp does not match initial timestamp");
    }

    function testMultiBlockDepositAndWithdrawMax(uint256 amount, uint256 elapsedTime) public {
        //uint256 maxYearsThatCanBeElapsed = 1_354; // Estimate of the absolute maximum number of years that can be elapsed before arithmatic overflow due to RAY mul
        uint256 maxYearsThatCanBeElapsed = 1_000;
        amount = bound(amount, 1, 1_000_000_000_000 ether);
        elapsedTime = bound(elapsedTime, 0, 365 days * maxYearsThatCanBeElapsed);

        uint256 blockTimestamp = block.timestamp;

        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        TestErc20 asset = new TestErc20();
        address account1 = makeAddr("account1");
        vm.prank(account1);
        asset.mint(account1, amount);
        vm.prank(account1);
        asset.approve(address(vault), amount);
        vm.prank(account1);
        vault.deposit(account1, address(asset), amount);

        uint256 assetBalance = vault.getAccountBalance(account1);
        // Check
        assertGe(assetBalance, amount - 1, "Asset balance too low compared to initial deposited amount");
        assertLe(assetBalance, amount, "Asset balance too high compared to initial deposited amount");

        // Withdraw after advancing block some time
        vm.warp(blockTimestamp + elapsedTime);

        assetBalance = vault.getAccountBalance(account1);

        uint256 assetsEarned = assetBalance - amount;
        asset.mint(address(vault), assetsEarned);

        vm.prank(account1);
        uint256 assetsWithdrawn = vault.withdraw(account1, address(asset), assetBalance);

        uint256 assetBalanceAfterWithdraw = vault.getAccountBalance(account1);

        assertEq(assetBalance, assetsWithdrawn, "Asset balance does not match withdrawn amount");
        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");
    }

    function testOneUnitDepositSameBlock(uint256 previousDepositAmount) public {
        previousDepositAmount = bound(previousDepositAmount, 0, 1_000_000_000_000 ether);

        uint256 blockTimestamp = block.timestamp;

        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        TestErc20 asset = new TestErc20();
        address account1 = makeAddr("account1");
        if (previousDepositAmount > 0) {
            vm.prank(account1);
            asset.mint(account1, previousDepositAmount);
            vm.prank(account1);
            asset.approve(address(vault), previousDepositAmount);
            vm.prank(account1);
            vault.deposit(account1, address(asset), previousDepositAmount);
        }

        uint256 initialAssetBalance = vault.getAccountBalance(account1);
        assertEq(initialAssetBalance, previousDepositAmount, "Asset balance does not match initial deposited amount");

        vm.prank(account1);
        asset.mint(account1, 1);
        vm.prank(account1);
        asset.approve(address(vault), 1);
        vm.prank(account1);
        vault.deposit(account1, address(asset), 1);

        // Without advancing the block or timestamp, call full withdrawal
        vm.prank(account1);
        uint256 assetsWithdrawn = vault.withdraw(account1, address(asset), initialAssetBalance + 1);

        uint256 assetBalanceAfterWithdraw = vault.getAccountBalance(account1);

        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");
        assertEq(
            assetsWithdrawn, initialAssetBalance + 1, "Assets withdrawn does not take into account the 1 unit deposit"
        );

        assertEq(block.timestamp, blockTimestamp, "Final block timestamp does not match initial timestamp");
    }

    function testMultiBlockDepositAndWithdrawMax_largeApy(uint256 amount, uint256 elapsedTime) public {
        // 1000000000377783247012652819 ~= 10% APY
        //uint256 maxYearsThatCanBeElapsed = 1_354; // Estimate of the absolute maximum number of years that can be elapsed before arithmatic overflow due to RAY mul
        uint256 maxYearsThatCanBeElapsed = 1_000;
        amount = bound(amount, 1, 1_000_000_000_000 ether);
        elapsedTime = bound(elapsedTime, 0, 365 days * maxYearsThatCanBeElapsed);

        uint256 blockTimestamp = block.timestamp;

        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000000377783247012652819;
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        TestErc20 asset = new TestErc20();

        address account1 = makeAddr("account1");
        vm.prank(account1);
        asset.mint(account1, amount);
        vm.prank(account1);
        asset.approve(address(vault), amount);
        vm.prank(account1);
        vault.deposit(account1, address(asset), amount);

        uint256 assetBalance = vault.getAccountBalance(account1);
        assertGe(assetBalance, amount - 1, "Asset balance too low compared to initial deposited amount");
        assertLe(assetBalance, amount, "Asset balance too high compared to initial deposited amount");

        // Withdraw after advancing block some time
        vm.warp(blockTimestamp + elapsedTime);

        assetBalance = vault.getAccountBalance(account1);

        uint256 assetsEarned = assetBalance - amount;
        asset.mint(address(vault), assetsEarned);

        vm.prank(account1);
        uint256 assetsWithdrawn = vault.withdraw(account1, address(asset), assetBalance);

        uint256 assetBalanceAfterWithdraw = vault.getAccountBalance(account1);

        assertEq(assetBalance, assetsWithdrawn, "Asset balance does not match withdrawn amount");
        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");
    }

    function testMultiBlockDepositAndWithdrawMax_multiAccount(uint256 amount, uint256 elapsedTime) public {
        // 1000000000377783247012652819 ~= 10% APY
        uint256 maxYearsThatCanBeElapsed = 100;
        amount = bound(amount, 1, 1_000_000_000_000 ether);
        elapsedTime = bound(elapsedTime, 0, 365 days * maxYearsThatCanBeElapsed);

        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000000377783247012652819;
        ExtendedBasedBoostedVault vault = new ExtendedBasedBoostedVault(owner, initialBasePerSecondRate);

        TestErc20 asset = new TestErc20();

        address account2 = makeAddr("account2");
        vm.prank(account2);
        asset.mint(account2, amount);
        vm.prank(account2);
        asset.approve(address(vault), amount);
        vm.prank(account2);
        vault.deposit(account2, address(asset), amount);
        uint256 assetBalanceAcct2 = vault.getAccountBalance(account2);
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

        uint256 assetBalanceAcct1 = vault.getAccountBalance(account1);

        assertGe(
            assetBalanceAcct1, amount - 1, "Asset balance too low compared to initial deposited amount for account1"
        );
        assertLe(assetBalanceAcct1, amount, "Asset balance too high compared to initial deposited amount for account1");

        // Withdraw after advancing block some time
        vm.warp(block.timestamp + elapsedTime);
        assetBalanceAcct1 = vault.getAccountBalance(account1);
        // Since balance is rounding down then withdrawing max will fail because shares will be 0
        vm.assume(assetBalanceAcct1 > 1);

        uint256 assetsEarned = assetBalanceAcct1 > amount ? assetBalanceAcct1 - amount : 0;
        if (assetsEarned > 0) {
            asset.mint(address(vault), assetsEarned);
        }

        vm.prank(account1);
        uint256 assetsWithdrawn = vault.withdraw(account1, address(asset), assetBalanceAcct1);

        console2.log("block timestamp after withdraw:", block.timestamp);
        uint256 assetBalanceAfterWithdraw = vault.getAccountBalance(account1);

        assertEq(assetBalanceAcct1, assetsWithdrawn, "Asset balance does not match withdrawn amount");
        assertEq(assetBalanceAfterWithdraw, 0, "Asset balance after withdrawal is not 0");
    }

    function testNextBlockDepositAndSetBoost() public {
        // TODO:
    }

    function testSetBoostsOver10Years() public {
        // Context: - find driver of value delta between ending balance of (5% base) APY vs (4% base + 1% boost) APY
        //          - add intermittent boosts across the time period of the initial deposit made
        //          - as of the writing of this test we concluded that intermittent deposits/withdrawals were not a driver of divergence in actual vs expected at the end of the 10 years
        // WolframAlpha: 2,000,000,000 * 1.05^10 = 3,257,789,253.5548828125
        uint256 originalDeposit = 2_000_000_000 ether;

        address owner = address(this);
        uint256 initialBasePerSecondRate = 1000000001243680656318820313; // ~4% APY
        IBasedBoostedVault vault = _deployVault(owner, initialBasePerSecondRate);

        // Asset deposit
        TestErc20 asset = new TestErc20();
        asset.mint(address(this), originalDeposit);
        asset.approve(address(vault), originalDeposit);
        vault.deposit(address(this), address(asset), originalDeposit);

        asset.approve(address(vault), originalDeposit);

        uint256 BOOST_4_TO_5 = 1000000000303445301167003084;

        // Set initial boost to set effective rate from 4% APY to 5% APY
        vault.setBoost(address(this), BOOST_4_TO_5);

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
            vault.setBoost(address(this), BOOST_4_TO_5 + (addOneToBoost ? 1 : 0));
            addOneToBoost = !addOneToBoost;
        }

        console2.log("block.timestamp: ", block.timestamp);
        console2.log("endingBlockTs: ", endingBlockTs);
        assertEq(block.timestamp, endingBlockTs);

        uint256 thisUsdBalanceInVault = vault.getAccountBalance(address(this));

        console2.log("thisUsdBalanceInVault: ", thisUsdBalanceInVault);

        uint256 expectedBalance_After_10Years = 3_257_789_253_554882812500000000;
        console2.log("delta_account_1: ", expectedBalance_After_10Years - thisUsdBalanceInVault);
    }
}
