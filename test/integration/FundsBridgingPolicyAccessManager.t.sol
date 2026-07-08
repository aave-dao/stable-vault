// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {FundsBridgingPolicy} from "src/policies/FundsBridgingPolicy.sol";

/// @dev Integration test for `FundsBridgingPolicy` running behind a real `AccessManager`. Verifies that delayed
/// raise calls scheduled through `AccessManager` can be consumed inside a multicall alongside immediate lower
/// calls, across the different direction combinations.
contract FundsBridgingPolicyAccessManagerIntegrationTest is Test {
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal applier = makeAddr("applier");
    address internal asset = makeAddr("asset");
    address internal bridgeAdapter = makeAddr("bridgeAdapter");
    uint256 internal constant DEST_CHAIN_ID = 137;

    AccessManager internal accessManager;
    FundsBridgingPolicy internal policy;

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
        policy = new FundsBridgingPolicy(address(accessManager), applier);

        vm.startPrank(admin);

        bytes4[] memory raiseSelectors = new bytes4[](2);
        raiseSelectors[0] = FundsBridgingPolicy.raiseBridgingCapacity.selector;
        raiseSelectors[1] = FundsBridgingPolicy.raiseBridgingRefillRate.selector;
        accessManager.setTargetFunctionRole(address(policy), raiseSelectors, RATE_LIMIT_RAISER_ROLE);

        bytes4[] memory lowerSelectors = new bytes4[](2);
        lowerSelectors[0] = FundsBridgingPolicy.lowerBridgingCapacity.selector;
        lowerSelectors[1] = FundsBridgingPolicy.lowerBridgingRefillRate.selector;
        accessManager.setTargetFunctionRole(address(policy), lowerSelectors, RATE_LIMIT_LOWERER_ROLE);

        accessManager.grantRole(RATE_LIMIT_RAISER_ROLE, operator, 0);
        accessManager.grantRole(RATE_LIMIT_LOWERER_ROLE, operator, 0);

        vm.stopPrank();

        vm.startPrank(operator);
        policy.raiseBridgingCapacity(asset, DEST_CHAIN_ID, bridgeAdapter, DEFAULT_CAPACITY);
        policy.raiseBridgingRefillRate(asset, DEST_CHAIN_ID, bridgeAdapter, DEFAULT_REFILL_RATE);
        vm.stopPrank();

        vm.prank(admin);
        accessManager.grantRole(RATE_LIMIT_RAISER_ROLE, operator, RAISE_DELAY);
    }

    function test_atomicTransitionToUnlimited_succeedsWhenRaiseIsScheduledAndDelayElapsed() public {
        bytes memory raiseToUnlimitedData =
            abi.encodeCall(FundsBridgingPolicy.raiseBridgingCapacity, (asset, DEST_CHAIN_ID, bridgeAdapter, UNLIMITED));
        bytes memory lowerRateToZeroData =
            abi.encodeCall(FundsBridgingPolicy.lowerBridgingRefillRate, (asset, DEST_CHAIN_ID, bridgeAdapter, 0));

        vm.prank(operator);
        accessManager.schedule(address(policy), raiseToUnlimitedData, 0);

        vm.warp(block.timestamp + RAISE_DELAY + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerRateToZeroData;
        calls[1] = raiseToUnlimitedData;

        vm.prank(operator);
        policy.multicall(calls);

        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, DEST_CHAIN_ID, bridgeAdapter);
        assertEq(bucket.capacity, UNLIMITED);
        assertEq(bucket.refillRate, 0);
        assertEq(bucket.consumed, 0);
    }

    function test_atomicTransitionToUnlimited_revertsWhenRaiseIsNotScheduled() public {
        bytes memory raiseToUnlimitedData =
            abi.encodeCall(FundsBridgingPolicy.raiseBridgingCapacity, (asset, DEST_CHAIN_ID, bridgeAdapter, UNLIMITED));
        bytes memory lowerRateToZeroData =
            abi.encodeCall(FundsBridgingPolicy.lowerBridgingRefillRate, (asset, DEST_CHAIN_ID, bridgeAdapter, 0));

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerRateToZeroData;
        calls[1] = raiseToUnlimitedData;

        vm.prank(operator);
        vm.expectRevert();
        policy.multicall(calls);
    }

    function test_atomicTransitionToUnlimited_revertsBeforeScheduledRaiseIsReady() public {
        bytes memory raiseToUnlimitedData =
            abi.encodeCall(FundsBridgingPolicy.raiseBridgingCapacity, (asset, DEST_CHAIN_ID, bridgeAdapter, UNLIMITED));
        bytes memory lowerRateToZeroData =
            abi.encodeCall(FundsBridgingPolicy.lowerBridgingRefillRate, (asset, DEST_CHAIN_ID, bridgeAdapter, 0));

        vm.prank(operator);
        accessManager.schedule(address(policy), raiseToUnlimitedData, 0);

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
        bytes memory raiseCapData = abi.encodeCall(
            FundsBridgingPolicy.raiseBridgingCapacity, (asset, DEST_CHAIN_ID, bridgeAdapter, newCapacity)
        );
        bytes memory raiseRateData = abi.encodeCall(
            FundsBridgingPolicy.raiseBridgingRefillRate, (asset, DEST_CHAIN_ID, bridgeAdapter, newRefillRate)
        );

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

        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, DEST_CHAIN_ID, bridgeAdapter);
        assertEq(bucket.capacity, newCapacity);
        assertEq(bucket.refillRate, newRefillRate);
    }

    function test_atomicMulticall_raisesBothAxes_revertsWhenRefillRateRaiseIsNotScheduled() public {
        uint128 newCapacity = DEFAULT_CAPACITY * 2;
        uint128 newRefillRate = DEFAULT_REFILL_RATE * 2;
        bytes memory raiseCapData = abi.encodeCall(
            FundsBridgingPolicy.raiseBridgingCapacity, (asset, DEST_CHAIN_ID, bridgeAdapter, newCapacity)
        );
        bytes memory raiseRateData = abi.encodeCall(
            FundsBridgingPolicy.raiseBridgingRefillRate, (asset, DEST_CHAIN_ID, bridgeAdapter, newRefillRate)
        );

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
        bytes memory lowerCapData = abi.encodeCall(
            FundsBridgingPolicy.lowerBridgingCapacity, (asset, DEST_CHAIN_ID, bridgeAdapter, newCapacity)
        );
        bytes memory lowerRateData = abi.encodeCall(
            FundsBridgingPolicy.lowerBridgingRefillRate, (asset, DEST_CHAIN_ID, bridgeAdapter, newRefillRate)
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerCapData;
        calls[1] = lowerRateData;

        vm.prank(operator);
        policy.multicall(calls);

        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, DEST_CHAIN_ID, bridgeAdapter);
        assertEq(bucket.capacity, newCapacity);
        assertEq(bucket.refillRate, newRefillRate);
    }

    function test_atomicMulticall_lowerCapacityAndRaiseRefillRate_succeedsWhenRaiseIsScheduled() public {
        uint128 newCapacity = DEFAULT_CAPACITY / 2;
        uint128 newRefillRate = DEFAULT_REFILL_RATE * 2;
        bytes memory lowerCapData = abi.encodeCall(
            FundsBridgingPolicy.lowerBridgingCapacity, (asset, DEST_CHAIN_ID, bridgeAdapter, newCapacity)
        );
        bytes memory raiseRateData = abi.encodeCall(
            FundsBridgingPolicy.raiseBridgingRefillRate, (asset, DEST_CHAIN_ID, bridgeAdapter, newRefillRate)
        );

        vm.prank(operator);
        accessManager.schedule(address(policy), raiseRateData, 0);

        vm.warp(block.timestamp + RAISE_DELAY + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerCapData;
        calls[1] = raiseRateData;

        vm.prank(operator);
        policy.multicall(calls);

        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, DEST_CHAIN_ID, bridgeAdapter);
        assertEq(bucket.capacity, newCapacity);
        assertEq(bucket.refillRate, newRefillRate);
    }
}
