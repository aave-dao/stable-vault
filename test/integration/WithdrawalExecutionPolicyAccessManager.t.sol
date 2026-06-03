// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Test} from "forge-std/Test.sol";

import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";

/// @dev Integration test for redemption rate-limit setters on `WithdrawalExecutionPolicy` behind a real
/// `AccessManager`. Asserts the asymmetric tiering: lower selectors are NO_DELAY (immediate), raise selectors
/// require `schedule(...)` + delay + execute.
contract WithdrawalExecutionPolicyAccessManagerIntegrationTest is Test {
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal applier = makeAddr("applier");

    AccessManager internal accessManager;
    WithdrawalExecutionPolicy internal policy;

    uint64 internal constant RATE_LIMIT_RAISER_ROLE =
        uint64(uint256(keccak256("aave.stable-vault.test.RateLimitRaiser")));
    uint64 internal constant RATE_LIMIT_LOWERER_ROLE =
        uint64(uint256(keccak256("aave.stable-vault.test.RateLimitLowerer")));
    uint64 internal constant ADMIN_ROLE = 0;

    uint32 internal constant RAISE_DELAY = 1 days;

    uint128 internal constant MIN_CAPACITY = 1;
    uint128 internal constant MIN_REFILL_RATE = 1;
    uint128 internal constant DEFAULT_CAPACITY = 1_000;
    uint128 internal constant DEFAULT_REFILL_RATE = 10;

    function setUp() public {
        vm.warp(1_000_000);
        accessManager = new AccessManager(admin);

        policy = new WithdrawalExecutionPolicy(address(accessManager), applier, 0, MIN_CAPACITY, MIN_REFILL_RATE);

        vm.startPrank(admin);

        bytes4[] memory raiseSelectors = new bytes4[](2);
        raiseSelectors[0] = WithdrawalExecutionPolicy.raiseRedemptionCapacity.selector;
        raiseSelectors[1] = WithdrawalExecutionPolicy.raiseRedemptionRefillRate.selector;
        accessManager.setTargetFunctionRole(address(policy), raiseSelectors, RATE_LIMIT_RAISER_ROLE);

        bytes4[] memory lowerSelectors = new bytes4[](2);
        lowerSelectors[0] = WithdrawalExecutionPolicy.lowerRedemptionCapacity.selector;
        lowerSelectors[1] = WithdrawalExecutionPolicy.lowerRedemptionRefillRate.selector;
        accessManager.setTargetFunctionRole(address(policy), lowerSelectors, RATE_LIMIT_LOWERER_ROLE);

        accessManager.grantRole(RATE_LIMIT_RAISER_ROLE, operator, 0);
        accessManager.grantRole(RATE_LIMIT_LOWERER_ROLE, operator, 0);

        vm.stopPrank();

        vm.startPrank(operator);
        policy.raiseRedemptionCapacity(DEFAULT_CAPACITY);
        policy.raiseRedemptionRefillRate(DEFAULT_REFILL_RATE);
        vm.stopPrank();

        vm.prank(admin);
        accessManager.grantRole(RATE_LIMIT_RAISER_ROLE, operator, RAISE_DELAY);
    }

    function test_lowerSelectors_callableImmediatelyByLowererRole() public {
        vm.startPrank(operator);
        policy.lowerRedemptionCapacity(DEFAULT_CAPACITY / 2);
        policy.lowerRedemptionRefillRate(DEFAULT_REFILL_RATE / 2);
        vm.stopPrank();

        RateLimitBucketLib.Bucket memory bucket = policy.getRedemptionBucket();
        assertEq(bucket.capacity, DEFAULT_CAPACITY / 2);
        assertEq(bucket.refillRate, DEFAULT_REFILL_RATE / 2);
    }

    function test_raiseSelectors_revertWithoutSchedule() public {
        vm.startPrank(operator);
        vm.expectPartialRevert(IAccessManager.AccessManagerNotScheduled.selector);
        policy.raiseRedemptionCapacity(DEFAULT_CAPACITY * 2);
        vm.expectPartialRevert(IAccessManager.AccessManagerNotScheduled.selector);
        policy.raiseRedemptionRefillRate(DEFAULT_REFILL_RATE * 2);
        vm.stopPrank();
    }

    function test_raiseSelectors_revertBeforeDelay() public {
        bytes memory raiseCapData =
            abi.encodeCall(WithdrawalExecutionPolicy.raiseRedemptionCapacity, (DEFAULT_CAPACITY * 2));

        vm.prank(operator);
        accessManager.schedule(address(policy), raiseCapData, 0);

        // Schedule exists but the delay hasn't elapsed, so AccessManager rejects with `AccessManagerNotReady`.
        vm.prank(operator);
        vm.expectPartialRevert(IAccessManager.AccessManagerNotReady.selector);
        policy.raiseRedemptionCapacity(DEFAULT_CAPACITY * 2);
    }

    function test_raiseSelectors_succeedAfterScheduleAndDelay() public {
        bytes memory raiseCapData =
            abi.encodeCall(WithdrawalExecutionPolicy.raiseRedemptionCapacity, (DEFAULT_CAPACITY * 2));
        bytes memory raiseRateData =
            abi.encodeCall(WithdrawalExecutionPolicy.raiseRedemptionRefillRate, (DEFAULT_REFILL_RATE * 2));

        vm.startPrank(operator);
        accessManager.schedule(address(policy), raiseCapData, 0);
        accessManager.schedule(address(policy), raiseRateData, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + RAISE_DELAY + 1);

        vm.startPrank(operator);
        policy.raiseRedemptionCapacity(DEFAULT_CAPACITY * 2);
        policy.raiseRedemptionRefillRate(DEFAULT_REFILL_RATE * 2);
        vm.stopPrank();

        RateLimitBucketLib.Bucket memory bucket = policy.getRedemptionBucket();
        assertEq(bucket.capacity, DEFAULT_CAPACITY * 2);
        assertEq(bucket.refillRate, DEFAULT_REFILL_RATE * 2);
    }

    function test_lowerSelectors_rejectedForRaiserRole() public {
        address raiserOnly = makeAddr("raiserOnly");
        vm.prank(admin);
        accessManager.grantRole(RATE_LIMIT_RAISER_ROLE, raiserOnly, RAISE_DELAY);

        vm.prank(raiserOnly);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, raiserOnly));
        policy.lowerRedemptionCapacity(DEFAULT_CAPACITY / 2);
    }
}
