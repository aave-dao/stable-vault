// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AssetLib} from "src/libraries/AssetLib.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {Constants} from "src/types/Constants.sol";

/// @title GlobalRateLimitedPolicy
/// @author Aave Labs
/// @notice Base for policies that complement their per-key buckets with a single global bucket bounding total
/// throughput across all keys, with amounts normalized to 18 decimals so heterogeneous assets share one budget.
/// Inheriting policies own the public getter, setters, and events; this base holds the bucket and the consume/normalize
/// plumbing.
/// @dev The bucket lives in namespaced (ERC-7201) storage so inheriting it cannot collide with the inheritor's layout.
/// Override `_globalBucketStorage` to point at a different bucket, or `_normalizeToGlobalBucketUnit` to change the
/// unit.
abstract contract GlobalRateLimitedPolicy {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    /// @custom:storage-location erc7201:aave.storage.GlobalRateLimitedPolicy
    struct GlobalRateLimitedPolicyStorage {
        RateLimitBucketLib.Bucket globalBucket;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.GlobalRateLimitedPolicy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_GLOBAL_RATE_LIMITED_POLICY =
        0x800850c3cb1cda09882d66d101d4a321db444750ca06f44b0411866a63327c00;

    function $storage() private pure returns (GlobalRateLimitedPolicyStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_GLOBAL_RATE_LIMITED_POLICY
        }
    }

    /// @dev Storage pointer to the global bucket. Override to point at a different bucket.
    function _globalBucketStorage() internal view virtual returns (RateLimitBucketLib.Bucket storage) {
        return $storage().globalBucket;
    }

    /// @dev Consumes `amount` (in `asset` decimals) from the global bucket, normalized to 18 decimals.
    function _consumeGlobalBucket(address asset, uint256 amount) internal virtual {
        _globalBucketStorage().consume(_normalizeToGlobalBucketUnit(asset, amount));
    }

    /// @dev Whether the global bucket would accept `amount` (in `asset` decimals), normalized to 18 decimals.
    function _canConsumeGlobalBucket(address asset, uint256 amount) internal view virtual returns (bool) {
        return _globalBucketStorage().canConsume(_normalizeToGlobalBucketUnit(asset, amount));
    }

    /// @dev Normalizes `amount` from `asset` decimals to the global bucket's 18-decimal unit.
    function _normalizeToGlobalBucketUnit(address asset, uint256 amount) internal view virtual returns (uint256) {
        return AssetLib.convertDecimals(amount, AssetLib.getDecimals(asset), Constants.MAX_SUPPORTED_ASSET_DECIMALS);
    }

    /// @dev Raises the global capacity, returning the previous value. Use max uint128 to remove the limit.
    function _raiseGlobalBucketCapacity(uint128 newCapacity) internal virtual returns (uint128 oldCapacity) {
        RateLimitBucketLib.Bucket storage bucket = _globalBucketStorage();
        oldCapacity = bucket.capacity;
        bucket.raiseCapacity(newCapacity);
    }

    /// @dev Lowers the global capacity, returning the previous value. `newCapacity = 0` fully rate-limits all keys.
    function _lowerGlobalBucketCapacity(uint128 newCapacity) internal virtual returns (uint128 oldCapacity) {
        RateLimitBucketLib.Bucket storage bucket = _globalBucketStorage();
        oldCapacity = bucket.capacity;
        bucket.lowerCapacity(newCapacity);
    }

    /// @dev Raises the global refill rate, returning the previous value. Reverts when the capacity is unlimited.
    function _raiseGlobalBucketRefillRate(uint128 newRefillRate) internal virtual returns (uint128 oldRefillRate) {
        RateLimitBucketLib.Bucket storage bucket = _globalBucketStorage();
        oldRefillRate = bucket.refillRate;
        bucket.raiseRefillRate(newRefillRate);
    }

    /// @dev Lowers the global refill rate, returning the previous value. `newRefillRate = 0` stops the refill.
    function _lowerGlobalBucketRefillRate(uint128 newRefillRate) internal virtual returns (uint128 oldRefillRate) {
        RateLimitBucketLib.Bucket storage bucket = _globalBucketStorage();
        oldRefillRate = bucket.refillRate;
        bucket.lowerRefillRate(newRefillRate);
    }
}
