// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Errors} from "src/types/Errors.sol";

/// @title RateLimitBucketLib
/// @author Aave Labs
/// @notice Rate-limit primitive shared across policies. Each bucket has a maximum capacity and refills linearly at a
/// fixed rate per second; operations consume from the available capacity and revert when it is exhausted.
/// @dev Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity`: they can drain
/// the full bucket at the start of the interval and then match the refill rate for the remaining time. Callers
/// should set `capacity` with this in mind.
library RateLimitBucketLib {
    uint256 internal constant UNLIMITED_CAPACITY = type(uint128).max;

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

    /// @notice Thrown by `consume` when the operation amount exceeds the available capacity.
    /// @custom:selector 0x3f7b7a68
    error RateLimited();

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
    /// @param bucket The bucket to update.
    /// @param amount The amount to consume.
    function consume(Bucket storage bucket, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        uint256 capacity = bucket.capacity;
        uint256 available = preview(bucket);
        require(available >= amount, RateLimited());
        // `capacity - available` is the post-refill `consumed`; adding `amount` yields the new `consumed`.
        // Both terms are bounded by `capacity <= type(uint128).max`, so the cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.consumed = uint128(capacity - available + amount);
        // Casting to uint128 is safe because block.timestamp fits in uint128 for any practical chain lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.lastUpdate = uint128(block.timestamp);
    }

    /// @notice Updates a bucket's `(capacity, refillRate)`. The refill accrued at the old rate is settled to `now`
    /// and the post-refill `consumed` is carried forward, clamped to the new capacity, so a reconfigure cannot
    /// refill a drained bucket. The unlimited case (max uint128 on either side) skips the carry and starts the
    /// bucket at zero `consumed`, since `consumed` is meaningless for an unlimited bucket. `refillRate` must be `0`
    /// when `capacity` is max uint128.
    /// @param bucket The bucket to configure.
    /// @param capacity New capacity.
    /// @param refillRate New refill rate.
    function configure(Bucket storage bucket, uint128 capacity, uint128 refillRate) internal {
        require(capacity != UNLIMITED_CAPACITY || refillRate == 0, Errors.InvalidParameter());
        uint256 newConsumed;
        if (bucket.capacity != UNLIMITED_CAPACITY && capacity != UNLIMITED_CAPACITY) {
            uint256 available = preview(bucket);
            if (available < capacity) {
                newConsumed = capacity - available;
            }
        }
        bucket.capacity = capacity;
        bucket.refillRate = refillRate;
        // `newConsumed` is either 0 or `capacity - available < capacity <= type(uint128).max`.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.consumed = uint128(newConsumed);
        // Casting to uint128 is safe because block.timestamp fits in uint128 for any practical chain lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.lastUpdate = uint128(block.timestamp);
    }
}
