// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Test} from "forge-std/Test.sol";

import {IFundsBridgingPolicy} from "src/interfaces/IFundsBridgingPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {FundsBridgingPolicy} from "src/policies/FundsBridgingPolicy.sol";
import {Errors} from "src/types/Errors.sol";

import {MockAccessManager} from "test/mocks/MockAccessManager.sol";

contract FundsBridgingPolicyTest is Test {
    FundsBridgingPolicy internal policy;
    MockAccessManager internal accessManager;

    address internal admin = makeAddr("admin");
    address internal applier = makeAddr("applier");

    uint128 internal constant UNLIMITED = type(uint128).max;
    uint128 internal constant DEFAULT_CAPACITY = 1_000;
    uint128 internal constant DEFAULT_REFILL_RATE = 10;
    uint128 internal constant START_TIMESTAMP = 1_000_000;

    function setUp() public {
        accessManager = new MockAccessManager(admin);
        policy = new FundsBridgingPolicy(address(accessManager), applier);
        vm.warp(START_TIMESTAMP);
    }

    function _request(address asset, uint256 destChainId, address bridgeAdapter, uint256 amount)
        internal
        view
        returns (IFundsBridgingPolicy.FundsBridgingIntent memory)
    {
        return IFundsBridgingPolicy.FundsBridgingIntent({
            caller: applier, bridgeAdapter: bridgeAdapter, destChainId: destChainId, asset: asset, amount: amount
        });
    }

    function _setLimit(address asset, uint256 destChainId, address bridgeAdapter, uint128 capacity, uint128 refillRate)
        internal
    {
        vm.prank(admin);
        policy.loosenBridgingLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);

        if (capacity == UNLIMITED) {
            require(refillRate == 0, "_setLimit: UNLIMITED requires refillRate == 0");
            return;
        }

        vm.prank(admin);
        policy.tightenBridgingLimit(asset, destChainId, bridgeAdapter, capacity, 0);

        if (refillRate > 0) {
            vm.prank(admin);
            policy.loosenBridgingLimit(asset, destChainId, bridgeAdapter, capacity, refillRate);
        }
    }

    function _bound128(uint256 v, uint256 lo, uint256 hi) internal pure returns (uint128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(bound(v, lo, hi));
    }

    /////////////////////////////////// constructor ///////////////////////////////////

    function test_constructor_revertsOnZeroApplier() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new FundsBridgingPolicy(address(accessManager), address(0));
    }

    /////////////////////////////////// applyFundsBridgingPolicy: access ///////////////////////////////////

    function test_applyFundsBridgingPolicy_revertsIfCallerIsNotApplier(
        address caller,
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        vm.assume(caller != applier);

        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(caller);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));
    }

    function test_applyFundsBridgingPolicy_succeedsIfCallerIsApplier(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);

        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, 1));
    }

    /////////////////////////////////// applyFundsBridgingPolicy: behavior ///////////////////////////////////

    function test_applyFundsBridgingPolicy_emitsEvent(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);

        vm.expectEmit(true, true, true, true);
        emit IFundsBridgingPolicy.FundsBridgingPolicyApplied(applier, bridgeAdapter, destChainId, asset, amount);
        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));
    }

    function test_applyFundsBridgingPolicy_revertsForUnconfiguredRoute(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint256).max);

        vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));
    }

    function test_applyFundsBridgingPolicy_zeroAmountIsAlwaysAccepted(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, 0));
    }

    function test_applyFundsBridgingPolicy_unlimitedNeverConsumes(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);

        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));

        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, destChainId, bridgeAdapter);
        assertEq(bucket.consumed, 0);
        assertEq(bucket.capacity, UNLIMITED);
    }

    function test_applyFundsBridgingPolicy_consumesFromBucket(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));

        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, destChainId, bridgeAdapter);
        assertEq(bucket.consumed, amount);
    }

    function test_applyFundsBridgingPolicy_revertsWhenAmountExceedsCapacity(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        amount = bound(amount, DEFAULT_CAPACITY + 1, type(uint128).max);
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));
    }

    function test_applyFundsBridgingPolicy_perRouteIsolation_byAsset(
        address assetA,
        address assetB,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        vm.assume(assetA != assetB);
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(assetA, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        _setLimit(assetB, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(assetA, destChainId, bridgeAdapter, amount));

        assertEq(policy.getBridgingLimit(assetA, destChainId, bridgeAdapter).consumed, amount);
        assertEq(policy.getBridgingLimit(assetB, destChainId, bridgeAdapter).consumed, 0);
    }

    function test_applyFundsBridgingPolicy_perRouteIsolation_byDestChainId(
        address asset,
        uint256 destChainIdA,
        uint256 destChainIdB,
        address bridgeAdapter,
        uint256 amount
    ) public {
        vm.assume(destChainIdA != destChainIdB);
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(asset, destChainIdA, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        _setLimit(asset, destChainIdB, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainIdA, bridgeAdapter, amount));

        assertEq(policy.getBridgingLimit(asset, destChainIdA, bridgeAdapter).consumed, amount);
        assertEq(policy.getBridgingLimit(asset, destChainIdB, bridgeAdapter).consumed, 0);
    }

    function test_applyFundsBridgingPolicy_perRouteIsolation_byBridgeAdapter(
        address asset,
        uint256 destChainId,
        address bridgeAdapterA,
        address bridgeAdapterB,
        uint256 amount
    ) public {
        vm.assume(bridgeAdapterA != bridgeAdapterB);
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(asset, destChainId, bridgeAdapterA, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        _setLimit(asset, destChainId, bridgeAdapterB, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(applier);
        policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapterA, amount));

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapterA).consumed, amount);
        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapterB).consumed, 0);
    }

    /////////////////////////////////// previewFundsBridgingPolicy ///////////////////////////////////

    function test_previewFundsBridgingPolicy_unconfigured_isFalseForNonZero(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public view {
        amount = bound(amount, 1, type(uint256).max);
        assertFalse(policy.previewFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount)));
    }

    function test_previewFundsBridgingPolicy_unconfigured_isTrueForZero(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public view {
        assertTrue(policy.previewFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, 0)));
    }

    function test_previewFundsBridgingPolicy_unlimited_isAlwaysTrue(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);
        assertTrue(policy.previewFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount)));
    }

    function test_previewFundsBridgingPolicy_doesNotMutateState(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        RateLimitBucketLib.Bucket memory before = policy.getBridgingLimit(asset, destChainId, bridgeAdapter);

        policy.previewFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));

        RateLimitBucketLib.Bucket memory afterBucket = policy.getBridgingLimit(asset, destChainId, bridgeAdapter);
        assertEq(afterBucket.capacity, before.capacity);
        assertEq(afterBucket.refillRate, before.refillRate);
        assertEq(afterBucket.consumed, before.consumed);
        assertEq(afterBucket.lastUpdate, before.lastUpdate);
    }

    function test_previewFundsBridgingPolicy_matchesAppliedOutcome(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint256 amount
    ) public {
        amount = bound(amount, 0, DEFAULT_CAPACITY * 2);
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        bool previewed = policy.previewFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));
        if (previewed) {
            vm.prank(applier);
            policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));
        } else {
            vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
            vm.prank(applier);
            policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));
        }
    }

    /////////////////////////////////// loosenBridgingLimit ///////////////////////////////////

    function test_loosenBridgingLimit_revertsIfNotAuthorized(
        address caller,
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), FundsBridgingPolicy.loosenBridgingLimit.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.loosenBridgingLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_loosenBridgingLimit_emitsEventAndUpdatesBucket(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint128 capacity,
        uint128 refillRate
    ) public {
        capacity = _bound128(capacity, 1, UNLIMITED - 1);
        refillRate = _bound128(refillRate, 0, capacity);

        vm.expectEmit(true, true, true, true);
        emit FundsBridgingPolicy.BridgingLimitLoosened(asset, destChainId, bridgeAdapter, 0, 0, capacity, refillRate);
        vm.prank(admin);
        policy.loosenBridgingLimit(asset, destChainId, bridgeAdapter, capacity, refillRate);

        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, destChainId, bridgeAdapter);
        assertEq(bucket.capacity, capacity);
        assertEq(bucket.refillRate, refillRate);
    }

    function test_loosenBridgingLimit_acceptsUnlimitedSentinel(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        vm.prank(admin);
        policy.loosenBridgingLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).capacity, UNLIMITED);
    }

    function test_loosenBridgingLimit_revertsIfNeitherDimensionIncreases(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.loosenBridgingLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_loosenBridgingLimit_revertsIfStrictDecrease(address asset, uint256 destChainId, address bridgeAdapter)
        public
    {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.loosenBridgingLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY - 1, DEFAULT_REFILL_RATE - 1);
    }

    function test_loosenBridgingLimit_acceptsStrictIncreaseInOneDimension(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        policy.loosenBridgingLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY + 1, DEFAULT_REFILL_RATE);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).capacity, DEFAULT_CAPACITY + 1);
    }

    /////////////////////////////////// tightenBridgingLimit ///////////////////////////////////

    function test_tightenBridgingLimit_revertsIfNotAuthorized(
        address caller,
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), FundsBridgingPolicy.tightenBridgingLimit.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.tightenBridgingLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_tightenBridgingLimit_revertsIfUnlimited(address asset, uint256 destChainId, address bridgeAdapter)
        public
    {
        _setLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.tightenBridgingLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);
    }

    function test_tightenBridgingLimit_revertsIfNeitherDimensionDecreases(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.tightenBridgingLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_tightenBridgingLimit_revertsIfAnyDimensionIncreases(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.tightenBridgingLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY + 1, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.tightenBridgingLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE + 1);
    }

    function test_tightenBridgingLimit_acceptsZeroCapacityAsMaxTighten(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit FundsBridgingPolicy.BridgingLimitTightened(
            asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE, 0, 0
        );
        vm.prank(admin);
        policy.tightenBridgingLimit(asset, destChainId, bridgeAdapter, 0, 0);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).capacity, 0);
    }

    function test_tightenBridgingLimit_emitsEventAndUpdatesBucket(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit FundsBridgingPolicy.BridgingLimitTightened(
            asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE, 500, 5
        );
        vm.prank(admin);
        policy.tightenBridgingLimit(asset, destChainId, bridgeAdapter, 500, 5);

        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, destChainId, bridgeAdapter);
        assertEq(bucket.capacity, 500);
        assertEq(bucket.refillRate, 5);
    }

    /////////////////////////////////// getBridgingLimit ///////////////////////////////////

    function test_getBridgingLimit_returnsDefaultForUnknownRoute(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public view {
        RateLimitBucketLib.Bucket memory bucket = policy.getBridgingLimit(asset, destChainId, bridgeAdapter);
        assertEq(bucket.capacity, 0);
        assertEq(bucket.refillRate, 0);
        assertEq(bucket.consumed, 0);
        assertEq(bucket.lastUpdate, 0);
    }
}
