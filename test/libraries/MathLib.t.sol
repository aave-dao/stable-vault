// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MathLibWrapper} from "test/mocks/MathLibWrapper.sol";

import {console} from "forge-std/console.sol";

contract MathLibDifferentialTests is Test {
    MathLibWrapper internal w;

    function setUp() public {
        w = new MathLibWrapper();
    }

    function test_constants() public view {
        assertEq(w.RAY(), 1e27, "ray");
    }

    function test_fuzz_rayMul(uint256 a, uint256 b) public {
        // overflow case
        if (!(b == 0 || !(a > type(uint256).max / b))) {
            vm.expectRevert();
            w.rayMulDown(a, b);
            vm.expectRevert();
            w.rayMulUp(a, b);
        } else {
            assertEq(w.rayMulDown(a, b), (a * b) / w.RAY());
            assertEq(w.rayMulUp(a, b), a * b == 0 ? 0 : (a * b - 1) / w.RAY() + 1);
        }
    }

    function test_fuzz_rayDiv(uint256 a, uint256 b) public {
        if (b == 0 || (a > type(uint256).max / w.RAY())) {
            vm.expectRevert();
            w.rayDivDown(a, b);
            vm.expectRevert();
            w.rayDivUp(a, b);

            return;
        }

        assertEq(w.rayDivDown(a, b), (a * w.RAY()) / b);
        assertEq(w.rayDivUp(a, b), a == 0 ? 0 : (a * w.RAY() - 1) / b + 1);
    }

    function test_rayMul() public {
        assertEq(w.rayMulDown(0, 1e27), 0);
        assertEq(w.rayMulDown(1e27, 0), 0);
        assertEq(w.rayMulDown(0, 0), 0);

        assertEq(w.rayMulDown(2.5e27, 0.5e27), 1.25e27);
        assertEq(w.rayMulDown(3e27, 1e27), 3e27);
        assertEq(w.rayMulDown(369, 271), 0);
        assertEq(w.rayMulDown(412.2e27, 1e27), 412.2e27);
        assertEq(w.rayMulDown(6e27, 2e27), 12e27);

        assertEq(w.rayMulUp(0, 1e27), 0);
        assertEq(w.rayMulUp(1e27, 0), 0);
        assertEq(w.rayMulUp(0, 0), 0);

        assertEq(w.rayMulUp(2.5e27, 0.5e27), 1.25e27);
        assertEq(w.rayMulUp(3e27, 1e27), 3e27);
        assertEq(w.rayMulUp(369, 271), 1);
        assertEq(w.rayMulUp(412.2e27, 1e27), 412.2e27);
        assertEq(w.rayMulUp(6e27, 2e27), 12e27);
    }

    function test_rayDiv() public {
        assertEq(w.rayDivDown(0, 1e27), 0);
        vm.expectRevert();
        assertEq(w.rayDivDown(1e27, 0), 0);
        vm.expectRevert();
        assertEq(w.rayDivDown(0, 0), 0);

        assertEq(w.rayDivDown(2.5e27, 0.5e27), 5e27);
        assertEq(w.rayDivDown(412.2e27, 1e27), 412.2e27);
        assertEq(w.rayDivDown(8.745e27, 0.67e27), 13.052238805970149253731343283e27);
        assertEq(w.rayDivDown(6e27, 2e27), 3e27);
        assertEq(w.rayDivDown(1.25e27, 0.5e27), 2.5e27);
        assertEq(w.rayDivDown(3e27, 1e27), 3e27);
        assertEq(w.rayDivDown(2, 100000000000000e27), 0);

        assertEq(w.rayDivUp(0, 1e27), 0);
        vm.expectRevert();
        assertEq(w.rayDivUp(1e27, 0), 0);
        vm.expectRevert();
        assertEq(w.rayDivUp(0, 0), 0);

        assertEq(w.rayDivUp(2.5e27, 0.5e27), 5e27);
        assertEq(w.rayDivUp(412.2e27, 1e27), 412.2e27);
        assertEq(w.rayDivUp(8.745e27, 0.67e27), 13.052238805970149253731343284e27);
        assertEq(w.rayDivUp(6e27, 2e27), 3e27);
        assertEq(w.rayDivUp(1.25e27, 0.5e27), 2.5e27);
        assertEq(w.rayDivUp(3e27, 1e27), 3e27);
        assertEq(w.rayDivUp(2, 100000000000000e27), 1);
    }

    function testRPow() public {
        assertEq(w.rpow(0, 0), w.RAY());
        assertEq(w.rpow(1, 0), w.RAY());
        assertEq(w.rpow(0, 1), 0);
        assertEq(w.rpow(1, 1), 1);
        assertEq(w.rpow(2e27, 0), w.RAY());
        assertEq(w.rpow(2e27, 2), 4e27);
        assertEq(w.rpow(8e27, 3), 512e27);
        assertEq(w.rpow((w.RAY() * 95) / 100, 5), 773_780_937_500_000_000_000_000_000);
        assertEq(w.rpow(w.RAY() / 2, 10), 976_562_500_000_000_000_000_000);
        assertEq(w.rpow((w.RAY() * 101) / 100, 365), 37_783_434_332_887_158_877_616_604_907);
        assertEq(w.rpow(w.RAY() + 1e17, 1_000_000), 1_000_100_005_000_161_670_333_367_351);
        assertEq(w.rpow(2, type(uint128).max), 0);
    }

    function testRPowOverflowReverts() public {
        vm.expectRevert();
        w.rpow(2e27, type(uint128).max);
        vm.expectRevert();
        w.rpow(type(uint128).max, 3);
    }

    // TODO: Check if the below is okay with Spark AGPL-3.0-or-later License or we need to do our own tests:
    // The below tests were taken from Spark Vaults v2 repo:
    // https://github.com/sparkdotfi/spark-vaults-v2/blob/dev/test/Math.t.sol

    struct ApyVsrTestCase {
        uint256 apy;
        uint256 vsr;
    }

    // NOTE: The CSV data was sourced from Sky Ecosystem's VSR conversion table:
    //       https://ipfs.io/ipfs/QmVp4mhhbwWGTfbh2BzwQB9eiBrQBKiqcPRZCaAxNUaar6
    function fixtureApyVsr() public view returns (ApyVsrTestCase[] memory) {
        string memory csv = vm.readFile("test/tables/rpow-apy.csv");
        string[] memory rows = vm.split(csv, "\n");
        ApyVsrTestCase[] memory testCases = new ApyVsrTestCase[](rows.length);
        for (uint256 i = 0; i < rows.length; i++) {
            testCases[i] = ApyVsrTestCase({
                apy: vm.parseUint(vm.split(rows[i], ",")[0]), vsr: vm.parseUint(vm.split(rows[i], ",")[1])
            });
        }
        return testCases;
    }

    function table_rpow_apyVsr18Decimals(ApyVsrTestCase memory apyVsr) public view {
        uint256 deposit = 1_000_000e18;

        uint256 depositWithYieldApy = deposit * (10000 + apyVsr.apy) / 10000;
        uint256 depositWithYieldVsr = deposit * w.rpow(apyVsr.vsr, 365 days) / 1e27;

        assertApproxEqAbs(depositWithYieldApy, depositWithYieldVsr, 150_000); // 1.5e-13 difference maximum on 1m
    }

    function table_rpow_apyVsr6Decimals(ApyVsrTestCase memory apyVsr) public view {
        uint256 deposit = 1_000_000e6;

        uint256 depositWithYieldApy = deposit * (10000 + apyVsr.apy) / 10000;
        uint256 depositWithYieldVsr = deposit * w.rpow(apyVsr.vsr, 365 days) / 1e27;

        assertApproxEqAbs(depositWithYieldApy, depositWithYieldVsr, 1); // 1 unit of rounding error for 6 decimals
    }

    // Adding this test to demonstrate the upper bound values of rpow instead of failure mode testing.
    // MAX_VSR is 100% APY.
    function test_rpow_upperBoundValues() public {
        uint256 maxVsr = w.MAX_VSR();

        // Reverts between 75 and 80 years
        vm.expectRevert();
        w.rpow(maxVsr, 80 * 365 days);

        uint256 maxVsrChi = w.rpow(maxVsr, 75 * 365 days);

        // 37,778,931,862,957,161,634,615,052,296,000,273,248,252,349,772,281% accrued over 75 years at 100% APY
        // without drip getting called.
        assertEq(maxVsrChi, 3.7778931862957161634615052296000273248252349772281e49);
    }

    function test_rpow_lowerBoundValues() public view {
        uint256 minVsr = 1e27;

        uint256 minVsrChi = w.rpow(minVsr, 1000 * 365 days);

        assertEq(minVsrChi, 1e27);
    }
}
