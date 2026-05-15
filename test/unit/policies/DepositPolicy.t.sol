// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Test} from "forge-std/Test.sol";

import {IDepositPolicy} from "src/interfaces/IDepositPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";
import {Errors} from "src/types/Errors.sol";

import {MockAccessManager} from "test/mocks/MockAccessManager.sol";

contract DepositPolicyTest is Test {
    DepositPolicy internal policy;
    MockAccessManager internal accessManager;

    address internal admin = makeAddr("admin");
    address internal applier = makeAddr("applier");

    uint128 internal constant UNLIMITED = type(uint128).max;
    uint128 internal constant DEFAULT_CAPACITY = 1_000;
    uint128 internal constant DEFAULT_REFILL_RATE = 10;
    uint128 internal constant START_TIMESTAMP = 1_000_000;

    function setUp() public {
        accessManager = new MockAccessManager(admin);
        policy = new DepositPolicy(address(accessManager), applier);
        vm.warp(START_TIMESTAMP);
    }

    function _request(address asset, uint256 amount) internal view returns (IDepositPolicy.DepositIntent memory) {
        return IDepositPolicy.DepositIntent({
            caller: applier, user: address(this), asset: asset, amount: amount, policyData: ""
        });
    }

    /// @dev Brings `asset`'s bucket from the default (0, 0) state to `(capacity, refillRate)`.
    function _setLimit(address asset, uint128 capacity, uint128 refillRate) internal {
        if (capacity == UNLIMITED) {
            require(refillRate == 0, "_setLimit: UNLIMITED requires refillRate == 0");
            vm.prank(admin);
            policy.raiseDepositCapacity(asset, UNLIMITED);
            return;
        }
        if (capacity > 0) {
            vm.prank(admin);
            policy.raiseDepositCapacity(asset, capacity);
        }
        if (refillRate > 0) {
            vm.prank(admin);
            policy.raiseDepositRefillRate(asset, refillRate);
        }
    }

    function _bound128(uint256 v, uint256 lo, uint256 hi) internal pure returns (uint128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(bound(v, lo, hi));
    }

    /////////////////////////////////// constructor ///////////////////////////////////

    function test_constructor_revertsOnZeroApplier() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new DepositPolicy(address(accessManager), address(0));
    }

    /////////////////////////////////// applyDepositPolicy: access ///////////////////////////////////

    function test_applyDepositPolicy_revertsIfCallerIsNotApplier(address caller, address asset, uint256 amount) public {
        vm.assume(caller != applier);

        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(caller);
        policy.applyDepositPolicy(_request(asset, amount));
    }

    function test_applyDepositPolicy_succeedsIfCallerIsApplier(address asset) public {
        _setLimit(asset, UNLIMITED, 0);

        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, 1));
    }

    /////////////////////////////////// applyDepositPolicy: behavior ///////////////////////////////////

    function test_applyDepositPolicy_emitsEvent(address asset, uint256 amount) public {
        amount = bound(amount, 0, type(uint256).max);
        _setLimit(asset, UNLIMITED, 0);

        vm.expectEmit(true, true, true, true);
        emit IDepositPolicy.DepositPolicyApplied(applier, address(this), asset, amount);
        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, amount));
    }

    function test_applyDepositPolicy_revertsForUnconfiguredAsset(address asset, uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, uint256(0)));
        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, amount));
    }

    function test_applyDepositPolicy_zeroAmountIsAlwaysAccepted(address asset) public {
        // Even an unconfigured (cap=0) bucket accepts amount=0 because consume short-circuits.
        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, 0));
    }

    function test_applyDepositPolicy_unlimitedNeverConsumes(address asset, uint256 amount) public {
        _setLimit(asset, UNLIMITED, 0);

        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, amount));

        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.consumed, 0);
        assertEq(bucket.capacity, UNLIMITED);
    }

    function test_applyDepositPolicy_consumesFromBucket(address asset, uint256 amount) public {
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, amount));

        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.consumed, amount);
    }

    function test_applyDepositPolicy_revertsWhenAmountExceedsCapacity(address asset, uint256 amount) public {
        amount = bound(amount, DEFAULT_CAPACITY + 1, type(uint128).max);
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, DEFAULT_CAPACITY));
        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, amount));
    }

    function test_applyDepositPolicy_perAssetIsolation(address assetA, address assetB, uint256 amount) public {
        vm.assume(assetA != assetB);
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(assetA, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        _setLimit(assetB, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(applier);
        policy.applyDepositPolicy(_request(assetA, amount));

        assertEq(policy.getDepositLimit(assetA).consumed, amount);
        assertEq(policy.getDepositLimit(assetB).consumed, 0);
    }

    /////////////////////////////////// previewDepositPolicy ///////////////////////////////////

    function test_previewDepositPolicy_unconfigured_isFalseForNonZero(address asset, uint256 amount) public view {
        amount = bound(amount, 1, type(uint256).max);
        assertFalse(policy.previewDepositPolicy(_request(asset, amount)));
    }

    function test_previewDepositPolicy_unconfigured_isTrueForZero(address asset) public view {
        assertTrue(policy.previewDepositPolicy(_request(asset, 0)));
    }

    function test_previewDepositPolicy_unlimited_isAlwaysTrue(address asset, uint256 amount) public {
        _setLimit(asset, UNLIMITED, 0);
        assertTrue(policy.previewDepositPolicy(_request(asset, amount)));
    }

    function test_previewDepositPolicy_doesNotMutateState(address asset, uint256 amount) public {
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        RateLimitBucketLib.Bucket memory before = policy.getDepositLimit(asset);

        policy.previewDepositPolicy(_request(asset, amount));

        RateLimitBucketLib.Bucket memory afterBucket = policy.getDepositLimit(asset);
        assertEq(afterBucket.capacity, before.capacity);
        assertEq(afterBucket.refillRate, before.refillRate);
        assertEq(afterBucket.consumed, before.consumed);
        assertEq(afterBucket.lastUpdate, before.lastUpdate);
    }

    function test_previewDepositPolicy_matchesAppliedOutcome(address asset, uint256 amount) public {
        amount = bound(amount, 0, DEFAULT_CAPACITY * 2); // mix of accepted and rejected amounts
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        bool previewed = policy.previewDepositPolicy(_request(asset, amount));
        if (previewed) {
            vm.prank(applier);
            policy.applyDepositPolicy(_request(asset, amount));
        } else {
            vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, DEFAULT_CAPACITY));
            vm.prank(applier);
            policy.applyDepositPolicy(_request(asset, amount));
        }
    }

    /////////////////////////////////// raiseDepositCapacity ///////////////////////////////////

    function test_raiseDepositCapacity_revertsIfNotAuthorized(address caller, address asset) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.raiseDepositCapacity.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.raiseDepositCapacity(asset, DEFAULT_CAPACITY);
    }

    function test_raiseDepositCapacity_emitsEventAndUpdatesBucket(address asset, uint128 capacity) public {
        capacity = _bound128(capacity, 1, UNLIMITED - 1);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.DepositCapacityRaised(asset, 0, capacity);
        vm.prank(admin);
        policy.raiseDepositCapacity(asset, capacity);

        assertEq(policy.getDepositLimit(asset).capacity, capacity);
    }

    function test_raiseDepositCapacity_acceptsUnlimited(address asset) public {
        vm.prank(admin);
        policy.raiseDepositCapacity(asset, UNLIMITED);

        assertEq(policy.getDepositLimit(asset).capacity, UNLIMITED);
    }

    function test_raiseDepositCapacity_revertsIfNotStrictlyGreater(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, 0);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseDepositCapacity(asset, DEFAULT_CAPACITY);
    }

    function test_raiseDepositCapacity_revertsWhenUnlimitedWithNonzeroRate(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseDepositCapacity(asset, UNLIMITED);
    }

    /////////////////////////////////// lowerDepositCapacity ///////////////////////////////////

    function test_lowerDepositCapacity_revertsIfNotAuthorized(address caller, address asset) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.lowerDepositCapacity.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.lowerDepositCapacity(asset, 0);
    }

    function test_lowerDepositCapacity_emitsEventAndUpdatesBucket(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.DepositCapacityLowered(asset, DEFAULT_CAPACITY, 500);
        vm.prank(admin);
        policy.lowerDepositCapacity(asset, 500);

        assertEq(policy.getDepositLimit(asset).capacity, 500);
    }

    function test_lowerDepositCapacity_acceptsZero(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        policy.lowerDepositCapacity(asset, 0);

        assertEq(policy.getDepositLimit(asset).capacity, 0);
    }

    function test_lowerDepositCapacity_revertsIfNotStrictlyLess(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, 0);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.lowerDepositCapacity(asset, DEFAULT_CAPACITY);
    }

    /////////////////////////////////// raiseDepositRefillRate ///////////////////////////////////

    function test_raiseDepositRefillRate_revertsIfNotAuthorized(address caller, address asset) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.raiseDepositRefillRate.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.raiseDepositRefillRate(asset, 1);
    }

    function test_raiseDepositRefillRate_emitsEventAndUpdatesBucket(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, 0);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.DepositRefillRateRaised(asset, 0, DEFAULT_REFILL_RATE);
        vm.prank(admin);
        policy.raiseDepositRefillRate(asset, DEFAULT_REFILL_RATE);

        assertEq(policy.getDepositLimit(asset).refillRate, DEFAULT_REFILL_RATE);
    }

    function test_raiseDepositRefillRate_revertsIfUnlimitedCapacity(address asset) public {
        _setLimit(asset, UNLIMITED, 0);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseDepositRefillRate(asset, 1);
    }

    function test_raiseDepositRefillRate_revertsIfNotStrictlyGreater(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseDepositRefillRate(asset, DEFAULT_REFILL_RATE);
    }

    /////////////////////////////////// lowerDepositRefillRate ///////////////////////////////////

    function test_lowerDepositRefillRate_revertsIfNotAuthorized(address caller, address asset) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.lowerDepositRefillRate.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.lowerDepositRefillRate(asset, 0);
    }

    function test_lowerDepositRefillRate_emitsEventAndUpdatesBucket(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.DepositRefillRateLowered(asset, DEFAULT_REFILL_RATE, 5);
        vm.prank(admin);
        policy.lowerDepositRefillRate(asset, 5);

        assertEq(policy.getDepositLimit(asset).refillRate, 5);
    }

    function test_lowerDepositRefillRate_acceptsZero(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        policy.lowerDepositRefillRate(asset, 0);

        assertEq(policy.getDepositLimit(asset).refillRate, 0);
    }

    function test_lowerDepositRefillRate_revertsIfNotStrictlyLess(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.lowerDepositRefillRate(asset, DEFAULT_REFILL_RATE);
    }

    /////////////////////////////////// getDepositLimit ///////////////////////////////////

    function test_getDepositLimit_returnsDefaultForUnknownAsset(address asset) public view {
        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.capacity, 0);
        assertEq(bucket.refillRate, 0);
        assertEq(bucket.consumed, 0);
        assertEq(bucket.lastUpdate, 0);
    }
}
