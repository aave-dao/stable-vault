// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";

/// @dev Integration test for `DepositPolicy` running behind a real `AccessManager`. Verifies that delayed raise
/// calls scheduled through `AccessManager` can be consumed inside a multicall alongside immediate lower calls,
/// across the different direction combinations.
contract DepositPolicyAccessManagerIntegrationTest is Test {
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal applier = makeAddr("applier");
    address internal asset = makeAddr("asset");

    AccessManager internal accessManager;
    DepositPolicy internal policy;

    /// @dev ADMIN_ROLE is id 0 in OZ AccessManager. Keccak-based ids are well clear of that and document the
    /// intent: the operator only ever holds a rate-limit manager role, never the admin role.
    uint64 internal constant RATE_LIMIT_RAISER_ROLE =
        uint64(uint256(keccak256("aave.stable-vault.test.RateLimitRaiser")));
    uint64 internal constant RATE_LIMIT_LOWERER_ROLE =
        uint64(uint256(keccak256("aave.stable-vault.test.RateLimitLowerer")));
    uint64 internal constant ADMIN_ROLE = 0;

    uint32 internal constant RAISE_DELAY = 1 days;

    uint128 internal constant UNLIMITED = type(uint128).max;
    uint128 internal constant DEFAULT_CAPACITY = 1_000;
    uint128 internal constant DEFAULT_REFILL_RATE = 10;

    function setUp() public {
        vm.warp(1_000_000);
        accessManager = new AccessManager(admin);
        policy = new DepositPolicy(address(accessManager), applier);

        vm.startPrank(admin);

        // Map the two raise selectors to the raise role.
        bytes4[] memory raiseSelectors = new bytes4[](2);
        raiseSelectors[0] = DepositPolicy.raiseDepositCapacity.selector;
        raiseSelectors[1] = DepositPolicy.raiseDepositRefillRate.selector;
        accessManager.setTargetFunctionRole(address(policy), raiseSelectors, RATE_LIMIT_RAISER_ROLE);

        // Map the two lower selectors to the lower role.
        bytes4[] memory lowerSelectors = new bytes4[](2);
        lowerSelectors[0] = DepositPolicy.lowerDepositCapacity.selector;
        lowerSelectors[1] = DepositPolicy.lowerDepositRefillRate.selector;
        accessManager.setTargetFunctionRole(address(policy), lowerSelectors, RATE_LIMIT_LOWERER_ROLE);

        // Grant both roles to the operator with no delay so we can prime the bucket; the raise delay is set after.
        accessManager.grantRole(RATE_LIMIT_RAISER_ROLE, operator, 0);
        accessManager.grantRole(RATE_LIMIT_LOWERER_ROLE, operator, 0);

        vm.stopPrank();

        // Prime the bucket to (DEFAULT_CAPACITY, DEFAULT_REFILL_RATE) using the immediate path.
        vm.startPrank(operator);
        policy.raiseDepositCapacity(asset, DEFAULT_CAPACITY);
        policy.raiseDepositRefillRate(asset, DEFAULT_REFILL_RATE);
        vm.stopPrank();

        // Now apply the raise delay for the actual test path.
        vm.prank(admin);
        accessManager.grantRole(RATE_LIMIT_RAISER_ROLE, operator, RAISE_DELAY);
    }

    function test_atomicTransitionToUnlimited_succeedsWhenRaiseIsScheduledAndDelayElapsed() public {
        bytes memory raiseToUnlimitedData = abi.encodeCall(DepositPolicy.raiseDepositCapacity, (asset, UNLIMITED));
        bytes memory lowerRateToZeroData = abi.encodeCall(DepositPolicy.lowerDepositRefillRate, (asset, 0));

        // Operator schedules the raise. `when = 0` means "earliest allowed".
        vm.prank(operator);
        accessManager.schedule(address(policy), raiseToUnlimitedData, 0);

        // Wait past the execution delay.
        vm.warp(block.timestamp + RAISE_DELAY + 1);

        // Single multicall: lower first (immediate, also zeroes the rate so the raise's require is satisfied),
        // then raise (delayed, consumed against the schedule via AccessManager.consumeScheduledOp).
        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerRateToZeroData;
        calls[1] = raiseToUnlimitedData;

        vm.prank(operator);
        policy.multicall(calls);

        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.capacity, UNLIMITED);
        assertEq(bucket.refillRate, 0);
        assertEq(bucket.consumed, 0);
    }

    function test_atomicTransitionToUnlimited_revertsWhenRaiseIsNotScheduled() public {
        bytes memory raiseToUnlimitedData = abi.encodeCall(DepositPolicy.raiseDepositCapacity, (asset, UNLIMITED));
        bytes memory lowerRateToZeroData = abi.encodeCall(DepositPolicy.lowerDepositRefillRate, (asset, 0));

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerRateToZeroData;
        calls[1] = raiseToUnlimitedData;

        // No schedule was placed: the inner raise call hits the unconsumed delay and reverts.
        vm.prank(operator);
        vm.expectRevert();
        policy.multicall(calls);
    }

    function test_atomicTransitionToUnlimited_revertsBeforeScheduledRaiseIsReady() public {
        bytes memory raiseToUnlimitedData = abi.encodeCall(DepositPolicy.raiseDepositCapacity, (asset, UNLIMITED));
        bytes memory lowerRateToZeroData = abi.encodeCall(DepositPolicy.lowerDepositRefillRate, (asset, 0));

        vm.prank(operator);
        accessManager.schedule(address(policy), raiseToUnlimitedData, 0);

        // Do not advance time past the delay.

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerRateToZeroData;
        calls[1] = raiseToUnlimitedData;

        vm.prank(operator);
        vm.expectRevert();
        policy.multicall(calls);
    }

    function test_atomicMulticall_raisesBothAxes_succeedsWhenBothAreScheduled() public {
        uint128 newCapacity = DEFAULT_CAPACITY * 2;
        uint128 newRefillRate = DEFAULT_REFILL_RATE * 2;
        bytes memory raiseCapData = abi.encodeCall(DepositPolicy.raiseDepositCapacity, (asset, newCapacity));
        bytes memory raiseRateData = abi.encodeCall(DepositPolicy.raiseDepositRefillRate, (asset, newRefillRate));

        vm.startPrank(operator);
        accessManager.schedule(address(policy), raiseCapData, 0);
        accessManager.schedule(address(policy), raiseRateData, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + RAISE_DELAY + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = raiseCapData;
        calls[1] = raiseRateData;

        vm.prank(operator);
        policy.multicall(calls);

        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.capacity, newCapacity);
        assertEq(bucket.refillRate, newRefillRate);
    }

    function test_atomicMulticall_raisesBothAxes_revertsWhenRefillRateRaiseIsNotScheduled() public {
        uint128 newCapacity = DEFAULT_CAPACITY * 2;
        uint128 newRefillRate = DEFAULT_REFILL_RATE * 2;
        bytes memory raiseCapData = abi.encodeCall(DepositPolicy.raiseDepositCapacity, (asset, newCapacity));
        bytes memory raiseRateData = abi.encodeCall(DepositPolicy.raiseDepositRefillRate, (asset, newRefillRate));

        // Schedule only the capacity raise.
        vm.prank(operator);
        accessManager.schedule(address(policy), raiseCapData, 0);

        vm.warp(block.timestamp + RAISE_DELAY + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = raiseCapData;
        calls[1] = raiseRateData;

        vm.prank(operator);
        vm.expectRevert();
        policy.multicall(calls);
    }

    function test_atomicMulticall_lowersBothAxes_succeedsWithoutScheduling() public {
        uint128 newCapacity = DEFAULT_CAPACITY / 2;
        uint128 newRefillRate = DEFAULT_REFILL_RATE / 2;
        bytes memory lowerCapData = abi.encodeCall(DepositPolicy.lowerDepositCapacity, (asset, newCapacity));
        bytes memory lowerRateData = abi.encodeCall(DepositPolicy.lowerDepositRefillRate, (asset, newRefillRate));

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerCapData;
        calls[1] = lowerRateData;

        vm.prank(operator);
        policy.multicall(calls);

        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.capacity, newCapacity);
        assertEq(bucket.refillRate, newRefillRate);
    }

    function test_atomicMulticall_lowerCapacityAndRaiseRefillRate_succeedsWhenRaiseIsScheduled() public {
        uint128 newCapacity = DEFAULT_CAPACITY / 2;
        uint128 newRefillRate = DEFAULT_REFILL_RATE * 2;
        bytes memory lowerCapData = abi.encodeCall(DepositPolicy.lowerDepositCapacity, (asset, newCapacity));
        bytes memory raiseRateData = abi.encodeCall(DepositPolicy.raiseDepositRefillRate, (asset, newRefillRate));

        vm.prank(operator);
        accessManager.schedule(address(policy), raiseRateData, 0);

        vm.warp(block.timestamp + RAISE_DELAY + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerCapData;
        calls[1] = raiseRateData;

        vm.prank(operator);
        policy.multicall(calls);

        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.capacity, newCapacity);
        assertEq(bucket.refillRate, newRefillRate);
    }
}
