// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

import {IDepositPolicy} from "src/interfaces/IDepositPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";
import {Constants} from "src/types/Constants.sol";
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

    /// @dev Builds an intent and mocks `decimals()` on the asset so `AssetLib.getDecimals` succeeds. Defaults to 18
    /// decimals; use `_requestWithDecimals` to test normalization for non-18-decimal assets.
    function _request(address asset, uint256 amount) internal returns (IDepositPolicy.DepositIntent memory) {
        return _requestWithDecimals(asset, amount, 18);
    }

    function _requestWithDecimals(address asset, uint256 amount, uint8 decimals)
        internal
        returns (IDepositPolicy.DepositIntent memory)
    {
        // `vm.mockCall` cannot intercept calls to the cheatcode/console addresses; skip those fuzz inputs.
        vm.assume(asset != address(vm) && asset != 0x000000000000000000636F6e736F6c652e6c6f67);
        vm.mockCall(asset, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(decimals));
        return IDepositPolicy.DepositIntent({
            caller: applier, user: address(this), asset: asset, amount: amount, policyData: ""
        });
    }

    /// @dev Brings `asset`'s bucket from the default (0, 0) state to `(capacity, refillRate)`. Also opens the global
    /// bucket to unlimited (idempotent) so per-asset tests do not get blocked by the default-zero global bucket;
    /// global-bucket tests lower it explicitly afterwards.
    function _setLimit(address asset, uint128 capacity, uint128 refillRate) internal {
        _openGlobal();
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

    function _openGlobal() internal {
        if (policy.getGlobalDepositLimit().capacity != UNLIMITED) {
            vm.prank(admin);
            policy.raiseGlobalDepositCapacity(UNLIMITED);
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
        IDepositPolicy.DepositIntent memory intent = _request(asset, amount);

        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(caller);
        policy.applyDepositPolicy(intent);
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
        IDepositPolicy.DepositIntent memory intent = _request(asset, amount);

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, uint256(0)));
        vm.prank(applier);
        policy.applyDepositPolicy(intent);
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
        IDepositPolicy.DepositIntent memory intent = _request(asset, amount);

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, DEFAULT_CAPACITY));
        vm.prank(applier);
        policy.applyDepositPolicy(intent);
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

    function test_previewDepositPolicy_unconfigured_isFalseForNonZero(address asset, uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        assertFalse(policy.previewDepositPolicy(_request(asset, amount)));
    }

    function test_previewDepositPolicy_unconfigured_isTrueForZero(address asset) public {
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

    /////////////////////////////////// global bucket: apply/preview ///////////////////////////////////

    function test_applyDepositPolicy_revertsWhenGlobalUnconfigured(address asset, uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        // Configure per-asset only; the global bucket is left at its default (zero capacity).
        vm.prank(admin);
        policy.raiseDepositCapacity(asset, UNLIMITED);
        IDepositPolicy.DepositIntent memory intent = _request(asset, amount);

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, uint256(0)));
        vm.prank(applier);
        policy.applyDepositPolicy(intent);
    }

    function test_applyDepositPolicy_consumesFromGlobalBucket(address asset, uint256 amount) public {
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setLimit(asset, UNLIMITED, 0);
        vm.prank(admin);
        policy.lowerGlobalDepositCapacity(DEFAULT_CAPACITY);

        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, amount));

        assertEq(policy.getGlobalDepositLimit().consumed, amount);
    }

    function test_applyDepositPolicy_normalizesGlobalConsumptionTo18Decimals(
        address asset,
        uint256 amount,
        uint8 assetDecimals
    ) public {
        assetDecimals = uint8(bound(uint256(assetDecimals), 0, Constants.MAX_SUPPORTED_ASSET_DECIMALS));
        uint256 scale = 10 ** (Constants.MAX_SUPPORTED_ASSET_DECIMALS - assetDecimals);
        // Bound `amount` so the normalized value fits in `uint128` (the bucket's `consumed` width).
        amount = bound(amount, 1, (UNLIMITED - 1) / scale);
        // Configure per-asset as unlimited and global with a large finite capacity so consumption is observable.
        vm.prank(admin);
        policy.raiseDepositCapacity(asset, UNLIMITED);
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(UNLIMITED - 1);

        vm.prank(applier);
        policy.applyDepositPolicy(_requestWithDecimals(asset, amount, assetDecimals));

        assertEq(policy.getGlobalDepositLimit().consumed, amount * scale);
    }

    function test_applyDepositPolicy_revertsWhenGlobalExceeded(address asset, uint256 amount) public {
        amount = bound(amount, DEFAULT_CAPACITY + 1, type(uint128).max);
        _setLimit(asset, UNLIMITED, 0);
        vm.prank(admin);
        policy.lowerGlobalDepositCapacity(DEFAULT_CAPACITY);
        IDepositPolicy.DepositIntent memory intent = _request(asset, amount);

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, DEFAULT_CAPACITY));
        vm.prank(applier);
        policy.applyDepositPolicy(intent);
    }

    function test_applyDepositPolicy_globalUnlimitedNeverConsumes(address asset, uint256 amount) public {
        _setLimit(asset, UNLIMITED, 0);

        vm.prank(applier);
        policy.applyDepositPolicy(_request(asset, amount));

        RateLimitBucketLib.Bucket memory bucket = policy.getGlobalDepositLimit();
        assertEq(bucket.consumed, 0);
        assertEq(bucket.capacity, UNLIMITED);
    }

    function test_previewDepositPolicy_returnsFalseWhenGlobalExceeded(address asset, uint256 amount) public {
        amount = bound(amount, DEFAULT_CAPACITY + 1, type(uint128).max);
        _setLimit(asset, UNLIMITED, 0);
        vm.prank(admin);
        policy.lowerGlobalDepositCapacity(DEFAULT_CAPACITY);

        assertFalse(policy.previewDepositPolicy(_request(asset, amount)));
    }

    function test_previewDepositPolicy_returnsFalseWhenGlobalUnconfigured(address asset, uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        vm.prank(admin);
        policy.raiseDepositCapacity(asset, UNLIMITED);

        assertFalse(policy.previewDepositPolicy(_request(asset, amount)));
    }

    /////////////////////////////////// raiseGlobalDepositCapacity ///////////////////////////////////

    function test_raiseGlobalDepositCapacity_revertsIfNotAuthorized(address caller) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.raiseGlobalDepositCapacity.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);
    }

    function test_raiseGlobalDepositCapacity_emitsEventAndUpdatesBucket(uint128 capacity) public {
        capacity = _bound128(capacity, 1, UNLIMITED - 1);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.GlobalDepositCapacityRaised(0, capacity);
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(capacity);

        assertEq(policy.getGlobalDepositLimit().capacity, capacity);
    }

    function test_raiseGlobalDepositCapacity_acceptsUnlimited() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(UNLIMITED);

        assertEq(policy.getGlobalDepositLimit().capacity, UNLIMITED);
    }

    function test_raiseGlobalDepositCapacity_revertsIfNotStrictlyGreater() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);
    }

    function test_raiseGlobalDepositCapacity_revertsWhenUnlimitedWithNonzeroRate() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(UNLIMITED);
    }

    /////////////////////////////////// lowerGlobalDepositCapacity ///////////////////////////////////

    function test_lowerGlobalDepositCapacity_revertsIfNotAuthorized(address caller) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.lowerGlobalDepositCapacity.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.lowerGlobalDepositCapacity(0);
    }

    function test_lowerGlobalDepositCapacity_emitsEventAndUpdatesBucket() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.GlobalDepositCapacityLowered(DEFAULT_CAPACITY, 500);
        vm.prank(admin);
        policy.lowerGlobalDepositCapacity(500);

        assertEq(policy.getGlobalDepositLimit().capacity, 500);
    }

    function test_lowerGlobalDepositCapacity_acceptsZero() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);

        vm.prank(admin);
        policy.lowerGlobalDepositCapacity(0);

        assertEq(policy.getGlobalDepositLimit().capacity, 0);
    }

    function test_lowerGlobalDepositCapacity_revertsIfNotStrictlyLess() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.lowerGlobalDepositCapacity(DEFAULT_CAPACITY);
    }

    /////////////////////////////////// raiseGlobalDepositRefillRate ///////////////////////////////////

    function test_raiseGlobalDepositRefillRate_revertsIfNotAuthorized(address caller) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.raiseGlobalDepositRefillRate.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.raiseGlobalDepositRefillRate(1);
    }

    function test_raiseGlobalDepositRefillRate_emitsEventAndUpdatesBucket() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.GlobalDepositRefillRateRaised(0, DEFAULT_REFILL_RATE);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(DEFAULT_REFILL_RATE);

        assertEq(policy.getGlobalDepositLimit().refillRate, DEFAULT_REFILL_RATE);
    }

    function test_raiseGlobalDepositRefillRate_revertsIfUnlimitedCapacity() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(UNLIMITED);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(1);
    }

    function test_raiseGlobalDepositRefillRate_revertsIfNotStrictlyGreater() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(DEFAULT_REFILL_RATE);
    }

    /////////////////////////////////// lowerGlobalDepositRefillRate ///////////////////////////////////

    function test_lowerGlobalDepositRefillRate_revertsIfNotAuthorized(address caller) public {
        vm.assume(caller != admin);
        accessManager.mockRejectCall(caller, address(policy), DepositPolicy.lowerGlobalDepositRefillRate.selector);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        policy.lowerGlobalDepositRefillRate(0);
    }

    function test_lowerGlobalDepositRefillRate_emitsEventAndUpdatesBucket() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(DEFAULT_REFILL_RATE);

        vm.expectEmit(true, true, true, true);
        emit DepositPolicy.GlobalDepositRefillRateLowered(DEFAULT_REFILL_RATE, 5);
        vm.prank(admin);
        policy.lowerGlobalDepositRefillRate(5);

        assertEq(policy.getGlobalDepositLimit().refillRate, 5);
    }

    function test_lowerGlobalDepositRefillRate_acceptsZero() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(DEFAULT_REFILL_RATE);

        vm.prank(admin);
        policy.lowerGlobalDepositRefillRate(0);

        assertEq(policy.getGlobalDepositLimit().refillRate, 0);
    }

    function test_lowerGlobalDepositRefillRate_revertsIfNotStrictlyLess() public {
        vm.prank(admin);
        policy.raiseGlobalDepositCapacity(DEFAULT_CAPACITY);
        vm.prank(admin);
        policy.raiseGlobalDepositRefillRate(DEFAULT_REFILL_RATE);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        policy.lowerGlobalDepositRefillRate(DEFAULT_REFILL_RATE);
    }

    /////////////////////////////////// getGlobalDepositLimit ///////////////////////////////////

    function test_getGlobalDepositLimit_returnsDefault() public view {
        RateLimitBucketLib.Bucket memory bucket = policy.getGlobalDepositLimit();
        assertEq(bucket.capacity, 0);
        assertEq(bucket.refillRate, 0);
        assertEq(bucket.consumed, 0);
        assertEq(bucket.lastUpdate, 0);
    }
}
