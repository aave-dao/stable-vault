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

    /////////////////////////////////// UNLIMITED_CAPACITY ///////////////////////////////////

    function test_unlimitedCapacity_isMaxUint128() public view {
        assertEq(w.unlimitedCapacity(), type(uint128).max);
    }

    /////////////////////////////////// preview ///////////////////////////////////

    function test_preview_default_isZero() public view {
        assertEq(w.preview(), 0);
    }

    function test_preview_afterConfigure_returnsCapacity() public {
        // configure preserves `consumed`. Default state has consumed = 0, so first enable carries 0 forward and
        // the bucket starts full at the new capacity.
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    function test_preview_afterConfigureFromConsumedZero_returnsCapacity() public {
        // Reach a state where consumed == 0 by configuring while old capacity is unlimited (carry-skip path).
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    function test_preview_afterConsume_returnsCapacityMinusConsumed() public {
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(300);
        assertEq(w.preview(), DEFAULT_CAPACITY - 300);
    }

    function test_preview_zeroRefillRate_doesNotRefill(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 365 days);
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, 0);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);

        assertEq(w.preview(), DEFAULT_CAPACITY - 400);
    }

    function test_preview_refillsLinearly(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 50); // < (consumed / refillRate) = 400/10 = 40, plus some slack
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);

        uint256 expected = elapsed >= 40 ? DEFAULT_CAPACITY : (DEFAULT_CAPACITY - 400 + elapsed * DEFAULT_REFILL_RATE);
        assertEq(w.preview(), expected);
    }

    function test_preview_refillCapsAtCapacity(uint256 elapsed) public {
        elapsed = bound(elapsed, 40, 365 days); // >= (consumed / refillRate) = 40
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);

        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    function test_preview_doesNotOverflowOnHugeElapsed() public {
        // refillRate * elapsed would overflow uint256 if not capped. Verify the cap.
        w.configure(UNLIMITED, 0);
        w.configure(UNLIMITED - 1, type(uint128).max);
        w.consume(1);
        vm.warp(type(uint128).max);
        assertEq(w.preview(), UNLIMITED - 1);
    }

    function test_preview_unlimited_returnsUnlimited() public {
        w.configure(UNLIMITED, 0);
        assertEq(w.preview(), UNLIMITED);
    }

    /////////////////////////////////// consume ///////////////////////////////////

    function test_consume_zeroAmount_isNoop() public {
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        uint128 lastUpdateBefore = w.getBucket().lastUpdate;

        w.consume(0);

        assertEq(w.getBucket().consumed, 0);
        assertEq(w.getBucket().lastUpdate, lastUpdateBefore);
    }

    function test_consume_revertsWhenAvailableLessThanAmount(uint256 amount) public {
        amount = bound(amount, DEFAULT_CAPACITY + 1, type(uint128).max);
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
        w.consume(amount);
    }

    function test_consume_revertsWhenCapacityIsZero() public {
        // Default state: capacity == 0, consumed == 0. preview returns 0. Any amount > 0 reverts.
        vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
        w.consume(1);
    }

    function test_consume_writesConsumedAndTimestamp(uint256 amount) public {
        amount = bound(amount, 1, DEFAULT_CAPACITY);
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(amount);

        assertEq(w.getBucket().consumed, amount);
        assertEq(w.getBucket().lastUpdate, block.timestamp);
    }

    function test_consume_drainsBucket() public {
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(DEFAULT_CAPACITY);

        assertEq(w.preview(), 0);
        assertEq(w.getBucket().consumed, DEFAULT_CAPACITY);
    }

    function test_consume_multipleConsumesAccumulate() public {
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, 0); // refillRate=0 to keep accumulation deterministic.

        w.consume(100);
        w.consume(200);
        w.consume(300);

        assertEq(w.getBucket().consumed, 600);
        assertEq(w.preview(), DEFAULT_CAPACITY - 600);
    }

    function test_consume_acrossRefill(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 50);
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

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

    /////////////////////////////////// configure ///////////////////////////////////

    function test_configure_revertsWhenUnlimitedAndRefillRateNonzero(uint128 refillRate) public {
        vm.assume(refillRate != 0);
        vm.expectRevert(Errors.InvalidParameter.selector);
        w.configure(UNLIMITED, refillRate);
    }

    function test_configure_acceptsZeroCapacityWithAnyRefillRate(uint128 refillRate) public {
        w.configure(0, refillRate);

        assertEq(w.getBucket().capacity, 0);
        assertEq(w.getBucket().refillRate, refillRate);
        assertEq(w.getBucket().consumed, 0);
        assertEq(w.getBucket().lastUpdate, block.timestamp);
    }

    function test_configure_acceptsLimitedCapacity(uint128 capacity, uint128 refillRate) public {
        capacity = _boundLimitedCapacity(capacity);
        w.configure(capacity, refillRate);

        assertEq(w.getBucket().capacity, capacity);
        assertEq(w.getBucket().refillRate, refillRate);
        assertEq(w.getBucket().lastUpdate, block.timestamp);
    }

    function test_configure_acceptsUnlimitedWithZeroRefillRate() public {
        w.configure(UNLIMITED, 0);

        assertEq(w.getBucket().capacity, UNLIMITED);
        assertEq(w.getBucket().refillRate, 0);
        assertEq(w.getBucket().consumed, 0);
        assertEq(w.getBucket().lastUpdate, block.timestamp);
    }

    function test_configure_fromUnlimitedToLimited_startsFull() public {
        w.configure(UNLIMITED, 0);

        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        assertEq(w.getBucket().consumed, 0);
        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    function test_configure_fromLimitedToUnlimited_zeroesConsumed() public {
        w.configure(UNLIMITED, 0);
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        w.consume(700);
        assertEq(w.getBucket().consumed, 700);

        w.configure(UNLIMITED, 0);

        assertEq(w.getBucket().consumed, 0);
        assertEq(w.preview(), UNLIMITED);
    }

    function test_configure_unlimitedToUnlimited_keepsConsumedZero() public {
        w.configure(UNLIMITED, 0);
        w.configure(UNLIMITED, 0);

        assertEq(w.getBucket().capacity, UNLIMITED);
        assertEq(w.getBucket().consumed, 0);
    }

    function test_configure_carriesConsumedForward(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 39); // < consumed/refillRate so no full refill
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(400);
        vm.warp(block.timestamp + elapsed);

        uint256 consumedBefore = 400 - elapsed * DEFAULT_REFILL_RATE; // post-refill consumed at `now`

        // Loosen by raising capacity. consumed is carried forward; available grows by the capacity delta.
        uint128 newCapacity = DEFAULT_CAPACITY * 2;
        w.configure(newCapacity, DEFAULT_REFILL_RATE);

        assertEq(w.getBucket().capacity, newCapacity);
        assertEq(w.getBucket().consumed, consumedBefore);
        assertEq(w.preview(), newCapacity - consumedBefore);
    }

    function test_configure_clampsConsumedWhenItExceedsNewCapacity() public {
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        w.consume(900); // consumed = 900, available = 100

        uint128 newCapacity = 500; // < consumed, must clamp consumed down to newCapacity
        w.configure(newCapacity, DEFAULT_REFILL_RATE);

        assertEq(w.getBucket().consumed, newCapacity);
        assertEq(w.preview(), 0);
    }

    function test_configure_zeroCapacityCarry_clampsToZero() public {
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        w.consume(300);

        w.configure(0, 0); // pause: consumed (300) clamped down to 0.

        assertEq(w.getBucket().capacity, 0);
        assertEq(w.getBucket().consumed, 0);
        assertEq(w.preview(), 0);
    }

    function test_configure_fromDefaultState_startsFull() public {
        // Default state has consumed == 0, which is carried forward; first enable starts full.
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        assertEq(w.getBucket().consumed, 0);
        assertEq(w.preview(), DEFAULT_CAPACITY);
    }

    function test_configure_pauseUnpauseStartsFull() public {
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
        w.consume(400);
        assertEq(w.preview(), DEFAULT_CAPACITY - 400);

        w.configure(0, 0); // pause: consumed (400) clamped to 0.
        w.configure(DEFAULT_CAPACITY, DEFAULT_REFILL_RATE); // unpause: consumed = 0 carried forward, bucket is full.
        assertEq(w.preview(), DEFAULT_CAPACITY);
        assertEq(w.getBucket().consumed, 0);
    }

    function test_configure_alwaysUpdatesLastUpdate(uint128 capacity, uint128 refillRate, uint256 warpAhead) public {
        capacity = _boundLimitedCapacity(capacity);
        warpAhead = bound(warpAhead, 0, 365 days);

        vm.warp(block.timestamp + warpAhead);
        w.configure(capacity, refillRate);

        assertEq(w.getBucket().lastUpdate, block.timestamp);
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

        w.configure(UNLIMITED, 0);
        w.configure(capacity, refillRate);
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

        w.configure(UNLIMITED, 0);
        w.configure(capacity, refillRate);
        w.consume(amountToConsume);

        assertLe(w.getBucket().consumed, capacity);
    }

    function test_invariant_2xCapacityRule_canExtractTwiceCapacityOverWindow(uint128 capacity, uint128 refillRate)
        public
    {
        capacity = _bound128(capacity, 2, UNLIMITED / 2 - 1);
        refillRate = _bound128(refillRate, 1, capacity);

        w.configure(UNLIMITED, 0);
        w.configure(capacity, refillRate);

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

        w.configure(UNLIMITED, 0);
        w.configure(capacity, refillRate);

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
        vm.expectRevert(RateLimitBucketLib.RateLimited.selector);
        w.consume(availableNow + 1);
    }
}
