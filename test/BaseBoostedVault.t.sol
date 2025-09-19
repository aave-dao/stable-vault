// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ExtendedBasedBoostedVault} from "./mocks/ExtendedBasedBoostedVault.sol";
import {TestErc20} from "./mocks/TestErc20.sol";

contract ExtendedBasedBoostedVaultT is Test {
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
}
