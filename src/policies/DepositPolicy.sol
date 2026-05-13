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
/// default to a zero-capacity bucket (fully rate-limited) until governance configures one; setting capacity to max
/// uint128 removes the limit entirely.
contract DepositPolicy is AccessManaged, IDepositPolicy {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    event DepositCapacityRaised(address indexed asset, uint128 oldCapacity, uint128 newCapacity);
    event DepositCapacityLowered(address indexed asset, uint128 oldCapacity, uint128 newCapacity);
    event DepositRefillRateRaised(address indexed asset, uint128 oldRefillRate, uint128 newRefillRate);
    event DepositRefillRateLowered(address indexed asset, uint128 oldRefillRate, uint128 newRefillRate);

    address internal immutable POLICY_APPLIER;

    mapping(address asset => RateLimitBucketLib.Bucket bucket) internal _buckets;

    modifier onlyPolicyApplier() {
        require(msg.sender == POLICY_APPLIER, Errors.NotAuthorized());
        _;
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param depositPolicyApplier Address allowed to apply the deposit policy (typically the StableVault).
    constructor(address accessManager, address depositPolicyApplier) AccessManaged(accessManager) {
        require(depositPolicyApplier != address(0), Errors.ZeroAddress());
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        POLICY_APPLIER = depositPolicyApplier;
    }

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

    /// @notice Raises the deposit capacity for `asset`. Use max uint128 to remove the limit.
    /// @dev Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity` (drain the full
    /// bucket at the start, then match the refill rate). Set `capacity` accordingly.
    function raiseDepositCapacity(address asset, uint128 newCapacity) external restricted {
        uint128 oldCapacity = _buckets[asset].capacity;
        _buckets[asset].raiseCapacity(newCapacity);
        emit DepositCapacityRaised(asset, oldCapacity, newCapacity);
    }

    /// @notice Lowers the deposit capacity for `asset`. `newCapacity = 0` fully rate-limits the asset.
    function lowerDepositCapacity(address asset, uint128 newCapacity) external restricted {
        uint128 oldCapacity = _buckets[asset].capacity;
        _buckets[asset].lowerCapacity(newCapacity);
        emit DepositCapacityLowered(asset, oldCapacity, newCapacity);
    }

    /// @notice Raises the deposit refill rate for `asset`.
    /// @dev Reverts when the asset's capacity is unlimited, since the rate must stay zero in that case.
    function raiseDepositRefillRate(address asset, uint128 newRefillRate) external restricted {
        uint128 oldRefillRate = _buckets[asset].refillRate;
        _buckets[asset].raiseRefillRate(newRefillRate);
        emit DepositRefillRateRaised(asset, oldRefillRate, newRefillRate);
    }

    /// @notice Lowers the deposit refill rate for `asset`. `newRefillRate = 0` stops the refill.
    function lowerDepositRefillRate(address asset, uint128 newRefillRate) external restricted {
        uint128 oldRefillRate = _buckets[asset].refillRate;
        _buckets[asset].lowerRefillRate(newRefillRate);
        emit DepositRefillRateLowered(asset, oldRefillRate, newRefillRate);
    }
}
