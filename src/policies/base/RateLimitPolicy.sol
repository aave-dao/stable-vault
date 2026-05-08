// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {Errors} from "src/types/Errors.sol";

/// @title RateLimitPolicy
/// @author Aave Labs
/// @notice Abstract base for rate-limited policies built on `RateLimitBucketLib`.
/// @dev Children own the storage layout (single or multiple buckets, which key to use for each bucket, etc.) and pass
/// bucket storage references into the helpers.
abstract contract RateLimitPolicy is AccessManaged {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    constructor(address accessManager) AccessManaged(accessManager) {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
    }

    /// @dev Validates a loosening change and writes it to `bucket`.
    /// @dev Setting `capacity` to max uint128 removes the limit (maximal loosening); otherwise at least one
    /// dimension must strictly increase. Same-or-tighter changes belong on the tighten path.
    /// @param bucket The bucket storage reference owned by the child contract.
    /// @param capacity New capacity.
    /// @param refillRate New refill rate.
    /// @return oldCapacity Previous capacity (for the child to emit in its event).
    /// @return oldRefillRate Previous refill rate (for the child to emit in its event).
    function _loosenBucket(RateLimitBucketLib.Bucket storage bucket, uint128 capacity, uint128 refillRate)
        internal
        returns (uint128 oldCapacity, uint128 oldRefillRate)
    {
        oldCapacity = bucket.capacity;
        oldRefillRate = bucket.refillRate;
        require(
            capacity == RateLimitBucketLib.UNLIMITED_CAPACITY || capacity > oldCapacity || refillRate > oldRefillRate,
            Errors.InvalidParameter()
        );
        bucket.configure(capacity, refillRate);
    }

    /// @dev Validates a tightening change and writes it to `bucket`. Both dimensions must be non-increasing and at
    /// least one must strictly decrease. Max uint128 is forbidden here because it loosens, use the loosen path.
    /// `capacity == 0` (fully rate-limited) is allowed as a maximal tighten.
    /// @param bucket The bucket storage reference owned by the child contract.
    /// @param capacity New capacity.
    /// @param refillRate New refill rate.
    /// @return oldCapacity Previous capacity (for the child to emit in its event).
    /// @return oldRefillRate Previous refill rate (for the child to emit in its event).
    function _tightenBucket(RateLimitBucketLib.Bucket storage bucket, uint128 capacity, uint128 refillRate)
        internal
        returns (uint128 oldCapacity, uint128 oldRefillRate)
    {
        require(capacity != RateLimitBucketLib.UNLIMITED_CAPACITY, Errors.InvalidParameter());
        oldCapacity = bucket.capacity;
        oldRefillRate = bucket.refillRate;
        require(
            capacity <= oldCapacity && refillRate <= oldRefillRate
                && (capacity < oldCapacity || refillRate < oldRefillRate),
            Errors.InvalidParameter()
        );
        bucket.configure(capacity, refillRate);
    }

    /// @dev Consumes `amount` from `bucket`. No-op when the bucket is unlimited (capacity is max uint128); otherwise
    /// delegates to `consume`, which reverts via `RateLimitBucketLib.RateLimited` when the bucket lacks capacity
    /// (including the default zero-capacity state).
    function _consumeBucket(RateLimitBucketLib.Bucket storage bucket, uint256 amount) internal {
        if (bucket.capacity == RateLimitBucketLib.UNLIMITED_CAPACITY) {
            return;
        }
        bucket.consume(amount);
    }

    /// @dev Returns whether `bucket` would accept a consumption of `amount`. Always true for unlimited buckets;
    /// false for zero-capacity buckets when `amount > 0`.
    function _canConsumeBucket(RateLimitBucketLib.Bucket storage bucket, uint256 amount) internal view returns (bool) {
        if (bucket.capacity == RateLimitBucketLib.UNLIMITED_CAPACITY) {
            return true;
        }
        return bucket.preview() >= amount;
    }
}
