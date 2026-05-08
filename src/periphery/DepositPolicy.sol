// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IDepositPolicy} from "src/interfaces/IDepositPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {Errors} from "src/types/Errors.sol";

/// @title DepositPolicy
/// @author Aave Labs
/// @notice Per-asset rate-limited deposit policy. Each asset has a deposit limit defined by a max capacity and a
/// per-second refill rate; deposits consume from the available capacity and revert when it is exhausted. Assets
/// without a configured limit are unrestricted.
contract DepositPolicy is AccessManaged, IDepositPolicy {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    /// @notice Public-facing snapshot of an asset's deposit limit.
    /// @param capacity The maximum amount that can be drained from a fully-refilled bucket.
    /// @param refillRate The per-second amount of capacity restored.
    /// @param available Available capacity at `block.timestamp`, refilled but not written back. `0` for unconfigured
    /// assets (`capacity == 0`).
    struct DepositLimit {
        uint128 capacity;
        uint128 refillRate;
        uint128 available;
    }

    event DepositLimitLoosened(
        address indexed asset, uint128 oldCapacity, uint128 oldRefillRate, uint128 newCapacity, uint128 newRefillRate
    );

    event DepositLimitTightened(
        address indexed asset, uint128 oldCapacity, uint128 oldRefillRate, uint128 newCapacity, uint128 newRefillRate
    );

    address internal immutable DEPOSIT_POLICY_APPLIER;

    mapping(address asset => RateLimitBucketLib.Bucket bucket) internal _buckets;

    modifier onlyDepositPolicyApplier() {
        require(msg.sender == DEPOSIT_POLICY_APPLIER, Errors.NotAuthorized());
        _;
    }

    constructor(address accessManager, address depositPolicyApplier) AccessManaged(accessManager) {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        require(depositPolicyApplier != address(0), Errors.ZeroAddress());
        DEPOSIT_POLICY_APPLIER = depositPolicyApplier;
    }

    /// @inheritdoc IDepositPolicy
    function applyDepositPolicy(DepositRequest calldata request)
        external
        override
        onlyDepositPolicyApplier
        returns (bool)
    {
        RateLimitBucketLib.Bucket storage bucket = _buckets[request.asset];
        if (bucket.capacity != 0) {
            bucket.consume(request.amount);
        }
        emit DepositPolicyApplied(request.caller, request.user, request.asset, request.amount);
        return true;
    }

    /// @inheritdoc IDepositPolicy
    function previewDepositPolicy(DepositRequest calldata request) external view override returns (bool) {
        RateLimitBucketLib.Bucket storage bucket = _buckets[request.asset];
        if (bucket.capacity == 0) {
            return true;
        }
        return bucket.preview() >= request.amount;
    }

    /// @notice Returns the current deposit limit for an asset.
    /// @param asset The asset to get the limit for.
    /// @return The current deposit limit for the asset.
    function getDepositLimit(address asset) external view returns (DepositLimit memory) {
        RateLimitBucketLib.Bucket storage bucket = _buckets[asset];
        return DepositLimit({
            capacity: bucket.capacity,
            refillRate: bucket.refillRate,
            available: bucket.capacity == 0 ? 0 : uint128(bucket.preview())
        });
    }

    /// @notice Loosens the limit (raises capacity and/or refill rate, or disables it via `capacity = 0`).
    /// @dev Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity` (drain the full
    /// bucket at the start, then match the refill rate). Set `capacity` accordingly.
    function loosenDepositLimit(address asset, uint128 capacity, uint128 refillRate) external restricted {
        RateLimitBucketLib.Bucket storage bucket = _buckets[asset];
        uint128 oldCapacity = bucket.capacity;
        uint128 oldRefillRate = bucket.refillRate;
        // `capacity == 0` disables the limit (maximal loosening); otherwise at least one dimension must strictly
        // increase. Same-or-tighter changes belong on `tightenDepositLimit`.
        require(capacity == 0 || capacity > oldCapacity || refillRate > oldRefillRate, Errors.InvalidParameter());
        bucket.configure(capacity, refillRate);
        emit DepositLimitLoosened(asset, oldCapacity, oldRefillRate, capacity, refillRate);
    }

    /// @notice Tightens the bucket. Both `capacity` and `refillRate` must be non-increasing and at least one must
    /// strictly decrease; `capacity = 0` (disable) is forbidden here because it would loosen the limit (use
    /// `loosenDepositLimit`).
    function tightenDepositLimit(address asset, uint128 capacity, uint128 refillRate) external restricted {
        require(capacity > 0, Errors.InvalidParameter());
        RateLimitBucketLib.Bucket storage bucket = _buckets[asset];
        uint128 oldCapacity = bucket.capacity;
        uint128 oldRefillRate = bucket.refillRate;
        require(
            capacity <= oldCapacity && refillRate <= oldRefillRate
                && (capacity < oldCapacity || refillRate < oldRefillRate),
            Errors.InvalidParameter()
        );
        bucket.configure(capacity, refillRate);
        emit DepositLimitTightened(asset, oldCapacity, oldRefillRate, capacity, refillRate);
    }
}
