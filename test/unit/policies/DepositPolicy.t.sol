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
            caller: applier, user: address(this), asset: asset, amount: amount, extraData: ""
        });
    }

    function _setLimit(address asset, uint128 capacity, uint128 refillRate) internal {
        // Multi-step path to land on (capacity, refillRate) with consumed = 0 (the "full bucket" baseline most
        // tests want). Starting from default (0, 0): loosen to UNLIMITED, then tighten to (capacity, 0), then
        // loosen the refillRate. The unlimited→limited step skips settle-and-carry, so consumed stays at 0.
        vm.prank(admin);
        policy.loosenDepositLimit(asset, UNLIMITED, 0);

        if (capacity == UNLIMITED) {
            require(refillRate == 0, "_setLimit: UNLIMITED requires refillRate == 0");
            return;
        }

        vm.prank(admin);
        policy.tightenDepositLimit(asset, capacity, 0);

        if (refillRate > 0) {
            vm.prank(admin);
            policy.loosenDepositLimit(asset, capacity, refillRate);
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

        vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
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

        vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
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
            vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
            vm.prank(applier);
            policy.applyDepositPolicy(_request(asset, amount));
        }
    }

    /////////////////////////////////// loosenDepositLimit ///////////////////////////////////

    function test_loosenDepositLimit_revertsIfNotAuthorized(address caller, address asset) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.loosenDepositLimit.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.loosenDepositLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_loosenDepositLimit_emitsEventAndUpdatesBucket(address asset, uint128 capacity, uint128 refillRate)
        public
    {
        capacity = _bound128(capacity, 1, UNLIMITED - 1);
        refillRate = _bound128(refillRate, 0, capacity);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.DepositLimitLoosened(asset, 0, 0, capacity, refillRate);
        vm.prank(admin);
        policy.loosenDepositLimit(asset, capacity, refillRate);

        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.capacity, capacity);
        assertEq(bucket.refillRate, refillRate);
    }

    function test_loosenDepositLimit_acceptsUnlimitedSentinel(address asset) public {
        vm.prank(admin);
        policy.loosenDepositLimit(asset, UNLIMITED, 0);

        assertEq(policy.getDepositLimit(asset).capacity, UNLIMITED);
    }

    function test_loosenDepositLimit_revertsIfNeitherDimensionIncreases(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.loosenDepositLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_loosenDepositLimit_revertsIfStrictDecrease(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.loosenDepositLimit(asset, DEFAULT_CAPACITY - 1, DEFAULT_REFILL_RATE - 1);
    }

    function test_loosenDepositLimit_acceptsStrictIncreaseInOneDimension(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        policy.loosenDepositLimit(asset, DEFAULT_CAPACITY + 1, DEFAULT_REFILL_RATE);

        assertEq(policy.getDepositLimit(asset).capacity, DEFAULT_CAPACITY + 1);
    }

    /////////////////////////////////// tightenDepositLimit ///////////////////////////////////

    function test_tightenDepositLimit_revertsIfNotAuthorized(address caller, address asset) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.tightenDepositLimit.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.tightenDepositLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_tightenDepositLimit_revertsIfUnlimited(address asset) public {
        _setLimit(asset, UNLIMITED, 0);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.tightenDepositLimit(asset, UNLIMITED, 0);
    }

    function test_tightenDepositLimit_revertsIfNeitherDimensionDecreases(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.tightenDepositLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_tightenDepositLimit_revertsIfAnyDimensionIncreases(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.tightenDepositLimit(asset, DEFAULT_CAPACITY + 1, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.tightenDepositLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE + 1);
    }

    function test_tightenDepositLimit_acceptsZeroCapacityAsMaxTighten(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.DepositLimitTightened(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE, 0, 0);
        vm.prank(admin);
        policy.tightenDepositLimit(asset, 0, 0);

        assertEq(policy.getDepositLimit(asset).capacity, 0);
    }

    function test_tightenDepositLimit_emitsEventAndUpdatesBucket(address asset) public {
        _setLimit(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.DepositLimitTightened(asset, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE, 500, 5);
        vm.prank(admin);
        policy.tightenDepositLimit(asset, 500, 5);

        RateLimitBucketLib.Bucket memory bucket = policy.getDepositLimit(asset);
        assertEq(bucket.capacity, 500);
        assertEq(bucket.refillRate, 5);
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
