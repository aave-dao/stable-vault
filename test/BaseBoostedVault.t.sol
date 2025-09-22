// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ExtendedBasedBoostedVault} from "./mocks/ExtendedBasedBoostedVault.sol";
import {TestErc20} from "./mocks/TestErc20.sol";
import {MathLib} from "./../src/libraries/MathLib.sol";

contract ExtendedBasedBoostedVaultT is Test {
    using MathLib for uint256;

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
}
