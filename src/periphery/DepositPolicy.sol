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
/// @notice Per-asset rate-limited deposit policy. Each asset has a bucket with a max capacity and a per-second refill
/// rate; deposits consume from the available capacity and revert when it is exhausted. Assets without a configured
/// bucket are unrestricted.
contract DepositPolicy is AccessManaged, IDepositPolicy {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    event DepositBucketSet(
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

    function getAvailableAmount(address asset) external view returns (uint256) {
        RateLimitBucketLib.Bucket storage bucket = _buckets[asset];
        if (bucket.capacity == 0) {
            // Unconfigured asset: no limit.
            return type(uint256).max;
        }
        return bucket.preview();
    }

    function getDepositBucket(address asset) external view returns (RateLimitBucketLib.Bucket memory) {
        return _buckets[asset];
    }

    // Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity` (drain the full
    // bucket at the start, then match the refill rate). Set `capacity` accordingly.
    function setDepositBucket(address asset, uint128 capacity, uint128 refillRate) external restricted {
        require(asset != address(0), Errors.ZeroAddress());
        RateLimitBucketLib.Bucket storage bucket = _buckets[asset];
        uint128 oldCapacity = bucket.capacity;
        uint128 oldRefillRate = bucket.refillRate;
        bucket.configure(capacity, refillRate);
        emit DepositBucketSet(asset, oldCapacity, oldRefillRate, capacity, refillRate);
    }
}
