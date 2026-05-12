// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IDepositPolicy} from "src/interfaces/IDepositPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {RateLimitPolicy} from "src/policies/base/RateLimitPolicy.sol";

/// @title DepositPolicy
/// @author Aave Labs
/// @notice Per-asset rate-limited deposit policy. Each asset has a deposit limit defined by a max capacity and a
/// per-second refill rate; deposits consume from the available capacity and revert when it is exhausted. Assets
/// default to a zero-capacity bucket (fully rate-limited) until governance configures one; setting capacity to max
/// uint128 removes the limit entirely.
contract DepositPolicy is RateLimitPolicy, IDepositPolicy {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    event DepositLimitLoosened(
        address indexed asset, uint128 oldCapacity, uint128 oldRefillRate, uint128 newCapacity, uint128 newRefillRate
    );

    event DepositLimitTightened(
        address indexed asset, uint128 oldCapacity, uint128 oldRefillRate, uint128 newCapacity, uint128 newRefillRate
    );

    mapping(address asset => RateLimitBucketLib.Bucket bucket) internal _buckets;

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param depositPolicyApplier Address allowed to apply the deposit policy (typically the StableVault).
    constructor(address accessManager, address depositPolicyApplier)
        RateLimitPolicy(accessManager, depositPolicyApplier)
    {}

    /// @inheritdoc IDepositPolicy
    function applyDepositPolicy(DepositIntent calldata deposit) external override onlyPolicyApplier {
        _buckets[deposit.asset].consume(deposit.amount);
        emit DepositPolicyApplied(deposit.caller, deposit.user, deposit.asset, deposit.amount);
    }

    /// @inheritdoc IDepositPolicy
    function previewDepositPolicy(DepositIntent calldata deposit) external view override returns (bool) {
        return _buckets[deposit.asset].canConsume(deposit.amount);
    }

    /// @notice Returns the current deposit-limit bucket for an asset.
    function getDepositLimit(address asset) external view returns (RateLimitBucketLib.Bucket memory) {
        return _buckets[asset];
    }

    /// @notice Loosens the limit (raises capacity and/or refill rate, or removes it by setting `capacity` to max
    /// uint128).
    /// @dev Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity` (drain the full
    /// bucket at the start, then match the refill rate). Set `capacity` accordingly.
    function loosenDepositLimit(address asset, uint128 capacity, uint128 refillRate) external restricted {
        (uint128 oldCapacity, uint128 oldRefillRate) = _loosenBucket(_buckets[asset], capacity, refillRate);
        emit DepositLimitLoosened(asset, oldCapacity, oldRefillRate, capacity, refillRate);
    }

    /// @notice Tightens the limit. Both `capacity` and `refillRate` must be non-increasing and at least one must
    /// strictly decrease. `capacity = 0` (fully rate-limited) is allowed as a maximal tighten; max uint128 is
    /// forbidden because it would loosen (use `loosenDepositLimit`).
    function tightenDepositLimit(address asset, uint128 capacity, uint128 refillRate) external restricted {
        (uint128 oldCapacity, uint128 oldRefillRate) = _tightenBucket(_buckets[asset], capacity, refillRate);
        emit DepositLimitTightened(asset, oldCapacity, oldRefillRate, capacity, refillRate);
    }
}
