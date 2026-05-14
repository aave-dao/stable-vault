// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {Errors} from "src/types/Errors.sol";

import {RateLimitBucketLibWrapper} from "test/mocks/RateLimitBucketLibWrapper.sol";

contract RateLimitBucketLibTest is Test {
    RateLimitBucketLibWrapper internal w;

    uint128 internal constant UNLIMITED = type(uint128).max;
    uint128 internal constant DEFAULT_CAPACITY = 1_000;
    uint128 internal constant DEFAULT_REFILL_RATE = 10;

    uint128 internal constant START_TIMESTAMP = 1_000_000;

    function setUp() public {
        w = new RateLimitBucketLibWrapper();
        vm.warp(START_TIMESTAMP);
    }

    function _bound128(uint256 v, uint256 lo, uint256 hi) internal pure returns (uint128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(bound(v, lo, hi));
    }

    function _boundLimitedCapacity(uint128 c) internal pure returns (uint128) {
        return _bound128(c, 1, UNLIMITED - 1);
    }

    function _boundLimitedRefillRate(uint128 r, uint128 capacity) internal pure returns (uint128) {
        return _bound128(r, 0, capacity);
    }

    /// @dev Brings the bucket from the default (0, 0, 0, 0) state to `(capacity, refillRate, 0, now)`.
    function _setBucket(uint128 capacity, uint128 refillRate) internal {
        if (capacity == UNLIMITED) {
            require(refillRate == 0, "_setBucket: UNLIMITED requires refillRate == 0");
            w.raiseCapacity(UNLIMITED);
            return;
        }
        if (capacity > 0) {
            w.raiseCapacity(capacity);
        }
        if (refillRate > 0) {
            w.raiseRefillRate(refillRate);
        }
    }

    /////////////////////////////////// UNLIMITED_CAPACITY ///////////////////////////////////

    function test_unlimitedCapacity_isMaxUint128() public view {
        assertEq(w.unlimitedCapacity(), type(uint128).max);
    }

    /////////////////////////////////// preview ///////////////////////////////////

    function test_preview_default_isZero() public view {
        assertEq(w.preview(), 0);
    }

    function test_preview_afterSetBucket_returnsCapacity() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    function test_preview_afterUnlimitedThenLimited_returnsCapacity() public {
        // Carry-skip path: transitioning from unlimited resets consumed to 0, so the bucket starts full.
        w.raiseCapacity(UNLIMITED);
        w.lowerCapacity(DEFAULT_CAPACITY);
        w.raiseRefillRate(DEFAULT_REFILL_RATE);
        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    function test_preview_afterConsume_returnsCapacityMinusConsumed() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(300);
        assertEq(w.preview(), DEFAULT_CAPACITY - 300);
    }

    function test_preview_zeroRefillRate_doesNotRefill(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 365 days);
        _setBucket(DEFAULT_CAPACITY, 0);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);

        assertEq(w.preview(), DEFAULT_CAPACITY - 400);
    }

    function test_preview_refillsLinearly(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 50); // < (consumed / refillRate) = 400/10 = 40, plus some slack
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);

        uint256 expected = elapsed >= 40 ? DEFAULT_CAPACITY : (DEFAULT_CAPACITY - 400 + elapsed * DEFAULT_REFILL_RATE);
        assertEq(w.preview(), expected);
    }

    function test_preview_refillCapsAtCapacity(uint256 elapsed) public {
        elapsed = bound(elapsed, 40, 365 days); // >= (consumed / refillRate) = 40
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);

        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    function test_preview_doesNotOverflowOnHugeElapsed() public {
        // refillRate * elapsed would overflow uint256 if not capped. Verify the cap.
        w.raiseCapacity(UNLIMITED - 1);
        w.raiseRefillRate(type(uint128).max);
        w.consume(1);
        vm.warp(type(uint128).max);
        assertEq(w.preview(), UNLIMITED - 1);
    }

    function test_preview_unlimited_returnsUnlimited() public {
        _setBucket(UNLIMITED, 0);
        assertEq(w.preview(), UNLIMITED);
    }

    /////////////////////////////////// consume ///////////////////////////////////

    function test_consume_zeroAmount_isNoop() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        uint128 lastUpdateBefore = w.getBucket().lastUpdate;

        w.consume(0);

        assertEq(w.getBucket().consumed, 0);
        assertEq(w.getBucket().lastUpdate, lastUpdateBefore);
    }

    function test_consume_revertsWhenAvailableLessThanAmount(uint256 amount) public {
        amount = bound(amount, DEFAULT_CAPACITY + 1, type(uint128).max);
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, amount, DEFAULT_CAPACITY));
        w.consume(amount);
    }

    function test_consume_revertsWhenCapacityIsZero() public {
        // Default state: capacity == 0, consumed == 0. preview returns 0. Any amount > 0 reverts.
        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, uint256(1), uint256(0)));
        w.consume(1);
    }

    function test_consume_writesConsumedAndTimestamp(uint256 amount) public {
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(amount);

        assertEq(w.getBucket().consumed, amount);
        assertEq(w.getBucket().lastUpdate, block.timestamp);
    }

    function test_consume_drainsBucket() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(DEFAULT_CAPACITY);

        assertEq(w.preview(), 0);
        assertEq(w.getBucket().consumed, DEFAULT_CAPACITY);
    }

    function test_consume_unlimited_isNoop(uint256 amount) public {
        _setBucket(UNLIMITED, 0);

        w.consume(amount);

        assertEq(w.getBucket().consumed, 0);
        assertEq(w.getBucket().capacity, UNLIMITED);
    }

    /////////////////////////////////// canConsume ///////////////////////////////////

    function test_canConsume_unlimited_isAlwaysTrue(uint256 amount) public {
        _setBucket(UNLIMITED, 0);
        assertTrue(w.canConsume(amount));
    }

    function test_canConsume_returnsAvailableComparison(uint256 amount) public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        if (amount <= DEFAULT_CAPACITY) {
            assertTrue(w.canConsume(amount));
        } else {
            assertFalse(w.canConsume(amount));
        }
    }

    function test_canConsume_zeroCapacity_isFalseForNonZero(uint256 amount) public view {
        amount = bound(amount, 1, type(uint256).max);
        assertFalse(w.canConsume(amount));
    }

    function test_consume_multipleConsumesAccumulate() public {
        _setBucket(DEFAULT_CAPACITY, 0); // refillRate=0 to keep accumulation deterministic.

        w.consume(100);
        w.consume(200);
        w.consume(300);

        assertEq(w.getBucket().consumed, 600);
        assertEq(w.preview(), DEFAULT_CAPACITY - 600);
    }

    function test_consume_acrossRefill(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 50);
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(500);
        vm.warp(block.timestamp + elapsed);

        uint256 refilled = elapsed * DEFAULT_REFILL_RATE;
        if (refilled > 500) {
            refilled = 500;
        }
        uint256 availableNow = DEFAULT_CAPACITY - 500 + refilled;

        // Consuming all currently available should leave zero available and persist correctly.
        w.consume(availableNow);
        assertEq(w.preview(), 0);
        assertEq(w.getBucket().consumed, DEFAULT_CAPACITY);
    }

    /////////////////////////////////// raiseCapacity ///////////////////////////////////

    function test_raiseCapacity_revertsIfNotStrictlyGreater(uint128 newCapacity) public {
        _setBucket(DEFAULT_CAPACITY, 0);
        newCapacity = _bound128(newCapacity, 0, DEFAULT_CAPACITY);
        vm.expectRevert(Errors.InvalidParameter.selector);
        w.raiseCapacity(newCapacity);
    }

    function test_raiseCapacity_revertsWhenRaisingToUnlimitedWithNonzeroRate() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        vm.expectRevert(Errors.InvalidParameter.selector);
        w.raiseCapacity(UNLIMITED);
    }

    function test_raiseCapacity_fromDefaultState_startsFull(uint128 capacity) public {
        capacity = _boundLimitedCapacity(capacity);
        w.raiseCapacity(capacity);

        assertEq(w.getBucket().capacity, capacity);
        assertEq(w.getBucket().consumed, 0);
        assertEq(w.preview(), capacity);
        assertEq(w.getBucket().lastUpdate, block.timestamp);
    }

    function test_raiseCapacity_toUnlimited_zeroesConsumed() public {
        // Build up a finite bucket with non-zero consumed, then drop the rate to 0 and raise to UNLIMITED.
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        w.consume(700);
        w.lowerRefillRate(0);

        w.raiseCapacity(UNLIMITED);

        assertEq(w.getBucket().capacity, UNLIMITED);
        assertEq(w.getBucket().consumed, 0);
        assertEq(w.preview(), UNLIMITED);
    }

    function test_raiseCapacity_carriesConsumedForward(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 39); // < consumed/refillRate so no full refill
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);

        uint256 consumedBefore = 400 - elapsed * DEFAULT_REFILL_RATE; // post-refill consumed at `now`

        uint128 newCapacity = DEFAULT_CAPACITY * 2;
        w.raiseCapacity(newCapacity);

        assertEq(w.getBucket().capacity, newCapacity);
        assertEq(w.getBucket().consumed, consumedBefore);
        assertEq(w.preview(), newCapacity - consumedBefore);
    }

    /////////////////////////////////// lowerCapacity ///////////////////////////////////

    function test_lowerCapacity_revertsIfNotStrictlyLess(uint128 newCapacity) public {
        _setBucket(DEFAULT_CAPACITY, 0);
        newCapacity = _bound128(newCapacity, DEFAULT_CAPACITY, UNLIMITED);
        vm.expectRevert(Errors.InvalidParameter.selector);
        w.lowerCapacity(newCapacity);
    }

    function test_lowerCapacity_revertsFromDefaultState() public {
        // Default capacity is 0; nothing strictly less than 0 fits in uint128.
        vm.expectRevert(Errors.InvalidParameter.selector);
        w.lowerCapacity(0);
    }

    function test_lowerCapacity_acceptsZero() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        w.consume(300);

        w.lowerCapacity(0); // consumed (300) clamped down to 0.

        assertEq(w.getBucket().capacity, 0);
        assertEq(w.getBucket().consumed, 0);
        assertEq(w.preview(), 0);
    }

    function test_lowerCapacity_clampsConsumedWhenItExceedsNewCapacity() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(900); // consumed = 900, available = 100

        uint128 newCapacity = 500; // < consumed, must clamp consumed down to newCapacity
        w.lowerCapacity(newCapacity);

        assertEq(w.getBucket().consumed, newCapacity);
        assertEq(w.preview(), 0);
    }

    function test_lowerCapacity_fromUnlimitedToLimited_startsFull() public {
        _setBucket(UNLIMITED, 0);

        w.lowerCapacity(DEFAULT_CAPACITY);

        assertEq(w.getBucket().capacity, DEFAULT_CAPACITY);
        assertEq(w.getBucket().consumed, 0);
        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    /////////////////////////////////// raiseRefillRate ///////////////////////////////////

    function test_raiseRefillRate_revertsIfUnlimitedCapacity() public {
        _setBucket(UNLIMITED, 0);
        vm.expectRevert(Errors.InvalidParameter.selector);
        w.raiseRefillRate(1);
    }

    function test_raiseRefillRate_revertsIfNotStrictlyGreater(uint128 newRate) public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        newRate = _bound128(newRate, 0, DEFAULT_REFILL_RATE);
        vm.expectRevert(Errors.InvalidParameter.selector);
        w.raiseRefillRate(newRate);
    }

    function test_raiseRefillRate_settlesAtOldRateBeforeChange(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 30); // < consumed/refillRate=40, partial refill
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);
        uint256 consumedAfterOldRefill = 400 - elapsed * DEFAULT_REFILL_RATE;

        uint128 newRate = DEFAULT_REFILL_RATE * 2;
        w.raiseRefillRate(newRate);

        assertEq(w.getBucket().refillRate, newRate);
        assertEq(w.getBucket().consumed, consumedAfterOldRefill);
        assertEq(w.getBucket().lastUpdate, block.timestamp);
    }

    /////////////////////////////////// lowerRefillRate ///////////////////////////////////

    function test_lowerRefillRate_revertsIfNotStrictlyLess(uint128 newRate) public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        newRate = _bound128(newRate, DEFAULT_REFILL_RATE, UNLIMITED);
        vm.expectRevert(Errors.InvalidParameter.selector);
        w.lowerRefillRate(newRate);
    }

    function test_lowerRefillRate_acceptsZero() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.lowerRefillRate(0);

        assertEq(w.getBucket().refillRate, 0);
    }

    function test_lowerRefillRate_settlesAtOldRateBeforeChange(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 30);
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);
        uint256 consumedAfterOldRefill = 400 - elapsed * DEFAULT_REFILL_RATE;

        w.lowerRefillRate(1);

        assertEq(w.getBucket().refillRate, 1);
        assertEq(w.getBucket().consumed, consumedAfterOldRefill);
        assertEq(w.getBucket().lastUpdate, block.timestamp);
    }

    /////////////////////////////////// pause / unpause ///////////////////////////////////

    function test_pauseUnpauseStartsFull() public {
        _setBucket(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        w.consume(400);
        assertEq(w.preview(), DEFAULT_CAPACITY - 400);

        // Pause: lower capacity to 0 (clamps consumed to 0), then lower rate to 0.
        w.lowerCapacity(0);
        w.lowerRefillRate(DEFAULT_REFILL_RATE - 1); // any strict decrease works; here pick one
        w.lowerRefillRate(0);

        // Unpause: raise capacity, then raise rate.
        w.raiseCapacity(DEFAULT_CAPACITY);
        w.raiseRefillRate(DEFAULT_REFILL_RATE);

        assertEq(w.preview(), DEFAULT_CAPACITY);
        assertEq(w.getBucket().consumed, 0);
    }

    /////////////////////////////////// invariants ///////////////////////////////////

    function test_invariant_availableNeverExceedsCapacity(
        uint128 capacity,
        uint128 refillRate,
        uint256 consumed,
        uint256 elapsed
    ) public {
        capacity = _boundLimitedCapacity(capacity);
        // refillRate is unbounded across uint128 — the lib does not enforce refillRate <= capacity, so the invariant
        // must hold even when refill outpaces the cap.
        consumed = bound(consumed, 0, capacity);
        elapsed = bound(elapsed, 0, type(uint128).max - START_TIMESTAMP);

        _setBucket(capacity, refillRate);
        if (consumed > 0) {
            w.consume(consumed);
        }
        vm.warp(block.timestamp + elapsed);

        assertLe(w.preview(), capacity);
    }

    function test_invariant_consumedNeverExceedsCapacity(uint128 capacity, uint128 refillRate, uint256 amountToConsume)
        public
    {
        capacity = _boundLimitedCapacity(capacity);
        refillRate = _boundLimitedRefillRate(refillRate, capacity);
        amountToConsume = bound(amountToConsume, 1, capacity);

        _setBucket(capacity, refillRate);
        w.consume(amountToConsume);

        assertLe(w.getBucket().consumed, capacity);
    }

    function test_invariant_2xCapacityRule_canExtractTwiceCapacityOverWindow(uint128 capacity, uint128 refillRate)
        public
    {
        capacity = _bound128(capacity, 2, UNLIMITED / 2 - 1);
        refillRate = _bound128(refillRate, 1, capacity);

        _setBucket(capacity, refillRate);

        // Drain at the start of the window.
        w.consume(capacity);

        // Warp the full window and consume the matched-refill amount in one shot. Bucket math is path-independent
        // for matched consumption that never drains, so this is equivalent to consuming `refillRate` each second.
        uint256 windowSeconds = uint256(capacity) / uint256(refillRate);
        uint256 matchedRefill = windowSeconds * uint256(refillRate);
        vm.warp(block.timestamp + windowSeconds);
        w.consume(matchedRefill);

        // Total over the window is capacity (drain) + matchedRefill, which is bounded by 2 * capacity.
        assertLe(uint256(capacity) + matchedRefill, uint256(capacity) * 2);
    }

    function test_invariant_2xCapacityRule_cannotExtractMoreThanTwiceCapacityInWindow(
        uint128 capacity,
        uint128 refillRate
    ) public {
        capacity = _bound128(capacity, 2, UNLIMITED / 2 - 1);
        refillRate = _bound128(refillRate, 1, capacity);

        _setBucket(capacity, refillRate);

        // Drain.
        w.consume(capacity);
        // Warp the full window.
        uint256 windowSeconds = uint256(capacity) / uint256(refillRate);
        vm.warp(block.timestamp + windowSeconds);

        // Available after warp is capped at capacity. Total extracted in window is then `capacity + capacity` only
        // if refill caught up exactly; in general it's `capacity + min(capacity, windowSeconds * refillRate)`.
        uint256 availableNow = w.preview();
        assertLe(availableNow, capacity);
        // Try to consume more than available — must revert.
        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, availableNow + 1, availableNow));
        w.consume(availableNow + 1);
    }
}
