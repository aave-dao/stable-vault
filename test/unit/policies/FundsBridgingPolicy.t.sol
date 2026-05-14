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
            caller: applier,
            bridgeAdapter: bridgeAdapter,
            destChainId: destChainId,
            asset: asset,
            amount: amount,
            policyData: ""
        });
    }

    /// @dev Brings the bucket for `(asset, destChainId, bridgeAdapter)` from the default (0, 0) state to
    /// `(capacity, refillRate)`.
    function _setLimit(address asset, uint256 destChainId, address bridgeAdapter, uint128 capacity, uint128 refillRate)
        internal
    {
        if (capacity == UNLIMITED) {
            require(refillRate == 0, "_setLimit: UNLIMITED requires refillRate == 0");
            vm.prank(admin);
            policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, UNLIMITED);
            return;
        }
        if (capacity > 0) {
            vm.prank(admin);
            policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, capacity);
        }
        if (refillRate > 0) {
            vm.prank(admin);
            policy.raiseBridgingRefillRate(asset, destChainId, bridgeAdapter, refillRate);
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

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, uint256(0)));
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

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, DEFAULT_CAPACITY));
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
            vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, DEFAULT_CAPACITY));
            vm.prank(applier);
            policy.applyFundsBridgingPolicy(_request(asset, destChainId, bridgeAdapter, amount));
        }
    }

    /////////////////////////////////// raiseBridgingCapacity ///////////////////////////////////

    function test_raiseBridgingCapacity_revertsIfNotAuthorized(
        address caller,
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), FundsBridgingPolicy.raiseBridgingCapacity.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY);
    }

    function test_raiseBridgingCapacity_emitsEventAndUpdatesBucket(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint128 capacity
    ) public {
        capacity = _bound128(capacity, 1, UNLIMITED - 1);

        vm.expectEmit(true, true, true, true);
        emit FundsBridgingPolicy.BridgingCapacityRaised(asset, destChainId, bridgeAdapter, 0, capacity);
        vm.prank(admin);
        policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, capacity);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).capacity, capacity);
    }

    function test_raiseBridgingCapacity_acceptsUnlimited(address asset, uint256 destChainId, address bridgeAdapter)
        public
    {
        vm.prank(admin);
        policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, UNLIMITED);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).capacity, UNLIMITED);
    }

    function test_raiseBridgingCapacity_revertsIfNotStrictlyGreater(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, 0);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY);
    }

    function test_raiseBridgingCapacity_revertsWhenUnlimitedWithNonzeroRate(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseBridgingCapacity(asset, destChainId, bridgeAdapter, UNLIMITED);
    }

    /////////////////////////////////// lowerBridgingCapacity ///////////////////////////////////

    function test_lowerBridgingCapacity_revertsIfNotAuthorized(
        address caller,
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), FundsBridgingPolicy.lowerBridgingCapacity.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.lowerBridgingCapacity(asset, destChainId, bridgeAdapter, 0);
    }

    function test_lowerBridgingCapacity_emitsEventAndUpdatesBucket(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit FundsBridgingPolicy.BridgingCapacityLowered(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, 500);
        vm.prank(admin);
        policy.lowerBridgingCapacity(asset, destChainId, bridgeAdapter, 500);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).capacity, 500);
    }

    function test_lowerBridgingCapacity_acceptsZero(address asset, uint256 destChainId, address bridgeAdapter) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        policy.lowerBridgingCapacity(asset, destChainId, bridgeAdapter, 0);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).capacity, 0);
    }

    function test_lowerBridgingCapacity_revertsIfNotStrictlyLess(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, 0);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.lowerBridgingCapacity(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY);
    }

    /////////////////////////////////// raiseBridgingRefillRate ///////////////////////////////////

    function test_raiseBridgingRefillRate_revertsIfNotAuthorized(
        address caller,
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), FundsBridgingPolicy.raiseBridgingRefillRate.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.raiseBridgingRefillRate(asset, destChainId, bridgeAdapter, 1);
    }

    function test_raiseBridgingRefillRate_emitsEventAndUpdatesBucket(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, 0);

        vm.expectEmit(true, true, true, true);
        emit FundsBridgingPolicy.BridgingRefillRateRaised(asset, destChainId, bridgeAdapter, 0, DEFAULT_REFILL_RATE);
        vm.prank(admin);
        policy.raiseBridgingRefillRate(asset, destChainId, bridgeAdapter, DEFAULT_REFILL_RATE);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).refillRate, DEFAULT_REFILL_RATE);
    }

    function test_raiseBridgingRefillRate_revertsIfUnlimitedCapacity(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, UNLIMITED, 0);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseBridgingRefillRate(asset, destChainId, bridgeAdapter, 1);
    }

    function test_raiseBridgingRefillRate_revertsIfNotStrictlyGreater(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseBridgingRefillRate(asset, destChainId, bridgeAdapter, DEFAULT_REFILL_RATE);
    }

    /////////////////////////////////// lowerBridgingRefillRate ///////////////////////////////////

    function test_lowerBridgingRefillRate_revertsIfNotAuthorized(
        address caller,
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), FundsBridgingPolicy.lowerBridgingRefillRate.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.lowerBridgingRefillRate(asset, destChainId, bridgeAdapter, 0);
    }

    function test_lowerBridgingRefillRate_emitsEventAndUpdatesBucket(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit FundsBridgingPolicy.BridgingRefillRateLowered(asset, destChainId, bridgeAdapter, DEFAULT_REFILL_RATE, 5);
        vm.prank(admin);
        policy.lowerBridgingRefillRate(asset, destChainId, bridgeAdapter, 5);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).refillRate, 5);
    }

    function test_lowerBridgingRefillRate_acceptsZero(address asset, uint256 destChainId, address bridgeAdapter)
        public
    {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        policy.lowerBridgingRefillRate(asset, destChainId, bridgeAdapter, 0);

        assertEq(policy.getBridgingLimit(asset, destChainId, bridgeAdapter).refillRate, 0);
    }

    function test_lowerBridgingRefillRate_revertsIfNotStrictlyLess(
        address asset,
        uint256 destChainId,
        address bridgeAdapter
    ) public {
        _setLimit(asset, destChainId, bridgeAdapter, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.lowerBridgingRefillRate(asset, destChainId, bridgeAdapter, DEFAULT_REFILL_RATE);
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
