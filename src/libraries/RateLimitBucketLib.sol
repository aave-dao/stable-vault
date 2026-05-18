// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Errors} from "src/types/Errors.sol";

/// @title RateLimitBucketLib
/// @author Aave Labs
/// @notice Rate-limit primitive shared across policies. Each bucket has a maximum capacity and refills linearly at a
/// fixed rate per second; operations consume from the available capacity and revert when it is exhausted.
/// @dev For any `(capacity, refillRate)` configuration, starting with a full bucket, a caller can extract
/// up to `2 * capacity` over a `capacity / refillRate`-second interval: they can consume the full bucket at the start
/// of the interval and then match the refill rate for the remaining time. The capacity should be set with this in mind.
/// @dev This library does not emit events; callers are responsible for emitting any events they need around bucket
/// state or configuration changes.
library RateLimitBucketLib {
    /// @notice State and configuration of a rate-limit bucket. Grouped so a single mapping value carries both the
    /// admin-set parameters and the live consumption tracking. By default a bucket is fully rate-limited (zero
    /// capacity); set `capacity` to max uint128 to remove the limit entirely.
    /// @param capacity Maximum capacity of the bucket.
    /// @param refillRate Amount of capacity restored per second.
    /// @param consumed Capacity used at `lastUpdate`, never above `capacity`. Available capacity is
    /// `capacity - consumed` after applying the refill accrued since `lastUpdate`.
    /// @param lastUpdate Unix timestamp at which `consumed` was last written.
    struct Bucket {
        uint128 capacity;
        uint128 refillRate;
        uint128 consumed;
        uint128 lastUpdate;
    }

    uint256 internal constant UNLIMITED_CAPACITY = type(uint128).max;

    /// @notice Thrown by `consume` when the operation amount exceeds the available capacity.
    /// @custom:selector 0x40df7ba9
    error RateLimited(uint256 amountToConsume, uint256 available);

    /// @notice Returns the available capacity at `block.timestamp`, refilled but not written back.
    /// @param bucket The bucket to read from.
    /// @return The capacity available for consumption right now.
    function preview(Bucket storage bucket) internal view returns (uint256) {
        uint256 capacity = bucket.capacity;
        uint256 consumed = bucket.consumed;
        if (consumed == 0) {
            return capacity;
        }
        uint256 refillRate = bucket.refillRate;
        if (refillRate == 0) {
            return capacity - consumed;
        }
        uint256 elapsed = block.timestamp - bucket.lastUpdate;
        if (elapsed == 0) {
            return capacity - consumed;
        }
        // Cap `elapsed` so `elapsed * refillRate` cannot overflow: past this point the bucket is fully refilled.
        uint256 maxElapsed = consumed / refillRate + 1;
        if (elapsed >= maxElapsed) {
            return capacity;
        }
        return capacity - consumed + elapsed * refillRate;
    }

    /// @notice Refills the bucket and consumes `amount` from the available capacity.
    /// @dev No-op when the bucket is unlimited (capacity == max uint128) or `amount == 0`.
    /// @dev Reverts with `RateLimited` when `amount` exceeds the available capacity.
    /// @param bucket The bucket to update.
    /// @param amount The amount to consume.
    function consume(Bucket storage bucket, uint256 amount) internal {
        uint256 capacity = bucket.capacity;
        if (capacity == UNLIMITED_CAPACITY || amount == 0) {
            return;
        }
        uint256 available = preview(bucket);
        require(available >= amount, RateLimited(amount, available));
        // `capacity - available` is the post-refill `consumed`; adding `amount` yields the new `consumed`.
        // Both terms are bounded by `capacity <= type(uint128).max`, so the cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.consumed = uint128(capacity - available + amount);
        // Casting to uint128 is safe because block.timestamp fits in uint128 for any practical chain lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.lastUpdate = uint128(block.timestamp);
    }

    /// @notice Returns whether `bucket` would accept a consumption of `amount` at `block.timestamp`.
    /// @dev Always true for unlimited buckets; false for zero-capacity buckets when `amount > 0`.
    /// @param bucket The bucket to read from.
    /// @param amount The amount that would be consumed.
    function canConsume(Bucket storage bucket, uint256 amount) internal view returns (bool) {
        if (bucket.capacity == UNLIMITED_CAPACITY) {
            return true;
        }
        return preview(bucket) >= amount;
    }

    /// @notice Raises `bucket.capacity` to `newCapacity`. Settles the refill accrued at the current rate and carries
    /// the post-refill `consumed` forward; transitioning to unlimited capacity resets `consumed` to zero since it is
    /// meaningless for an unlimited bucket.
    /// @dev `newCapacity` must strictly exceed the current capacity. Setting `newCapacity` to max uint128 (unlimited)
    /// requires the current refill rate to be zero.
    /// @param bucket The bucket to update.
    /// @param newCapacity The new capacity. Use max uint128 to set as unlimited.
    function raiseCapacity(Bucket storage bucket, uint128 newCapacity) internal {
        uint128 oldCapacity = bucket.capacity;
        require(newCapacity > oldCapacity, Errors.InvalidParameter());
        if (newCapacity == UNLIMITED_CAPACITY) {
            require(bucket.refillRate == 0, Errors.InvalidParameter());
        }
        _setCapacity(bucket, oldCapacity, newCapacity);
    }

    /// @notice Lowers `bucket.capacity` to `newCapacity`. Settles the refill accrued at the current rate and carries
    /// the post-refill `consumed` forward (clamped to `newCapacity`, so tightening below the current consumed forgives
    /// the overshoot).
    /// @dev `newCapacity` must be strictly below the current capacity. `newCapacity = 0` is allowed and fully rate
    /// limits the bucket.
    /// @dev Transitioning from `UNLIMITED_CAPACITY` to a finite capacity resets `consumed` to zero regardless of how
    /// much was consumed while unlimited, since `consumed` is not tracked for unlimited buckets. Operators tightening
    /// from unlimited should size `newCapacity` with this in mind: the new bucket is immediately fully available.
    /// @param bucket The bucket to update.
    /// @param newCapacity The new capacity.
    function lowerCapacity(Bucket storage bucket, uint128 newCapacity) internal {
        uint128 oldCapacity = bucket.capacity;
        require(newCapacity < oldCapacity, Errors.InvalidParameter());
        _setCapacity(bucket, oldCapacity, newCapacity);
    }

    /// @notice Raises `bucket.refillRate` to `newRefillRate`. Settles the refill accrued at the old rate before the
    /// rate change, so the new rate only applies to time after this call.
    /// @dev `newRefillRate` must strictly exceed the current refill rate. Reverts if `bucket.capacity` is unlimited,
    /// since the refill rate must stay zero in that case.
    /// @param bucket The bucket to update.
    /// @param newRefillRate The new refill rate, in capacity units per second.
    function raiseRefillRate(Bucket storage bucket, uint128 newRefillRate) internal {
        require(bucket.capacity != UNLIMITED_CAPACITY, Errors.InvalidParameter());
        uint128 oldRefillRate = bucket.refillRate;
        require(newRefillRate > oldRefillRate, Errors.InvalidParameter());
        _setRefillRate(bucket, newRefillRate);
    }

    /// @notice Lowers `bucket.refillRate` to `newRefillRate`. Settles the refill accrued at the old rate before the
    /// rate change, so the new rate only applies to time after this call.
    /// @dev `newRefillRate` must be strictly below the current refill rate. `newRefillRate = 0` is allowed and stops
    /// the refill.
    /// @param bucket The bucket to update.
    /// @param newRefillRate The new refill rate, in capacity units per second.
    function lowerRefillRate(Bucket storage bucket, uint128 newRefillRate) internal {
        uint128 oldRefillRate = bucket.refillRate;
        require(newRefillRate < oldRefillRate, Errors.InvalidParameter());
        _setRefillRate(bucket, newRefillRate);
    }

    function _setCapacity(Bucket storage bucket, uint128 oldCapacity, uint128 newCapacity) private {
        uint256 newConsumed;
        if (oldCapacity != UNLIMITED_CAPACITY && newCapacity != UNLIMITED_CAPACITY) {
            // Derive the post-refill `consumed` at `now` from preview's available (using the old rate),
            // then clamp it to the new capacity so the bucket invariant `consumed <= capacity` is preserved.
            newConsumed = uint256(oldCapacity) - preview(bucket);
            if (newConsumed > newCapacity) {
                newConsumed = newCapacity;
            }
        }
        bucket.capacity = newCapacity;
        // `newConsumed` is bounded by `newCapacity <= type(uint128).max`.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.consumed = uint128(newConsumed);
        // Casting to uint128 is safe because block.timestamp fits in uint128 for any practical chain lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.lastUpdate = uint128(block.timestamp);
    }

    function _setRefillRate(Bucket storage bucket, uint128 newRefillRate) private {
        // Capacity is finite here (callers gate the unlimited case), so `preview` returns `capacity - consumed_now`.
        uint256 newConsumed = uint256(bucket.capacity) - preview(bucket);
        bucket.refillRate = newRefillRate;
        // `newConsumed` is bounded by `bucket.capacity <= type(uint128).max`.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.consumed = uint128(newConsumed);
        // Casting to uint128 is safe because block.timestamp fits in uint128 for any practical chain lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.lastUpdate = uint128(block.timestamp);
    }
}
