// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IDepositPolicy} from "src/interfaces/IDepositPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {GlobalRateLimitedPolicy} from "src/policies/base/GlobalRateLimitedPolicy.sol";
import {Errors} from "src/types/Errors.sol";

/// @title DepositPolicy
/// @author Aave Labs
/// @notice Rate-limited deposit policy combining per-asset buckets with a global bucket. Each asset has its own bucket
/// denominated in the asset's native decimals; the global bucket bounds total deposit throughput across all assets,
/// with amounts normalized to 18 decimals (the maximum supported asset decimals). All buckets default to zero capacity
/// (fully rate-limited) until operator configures them; setting capacity to max uint128 removes the limit entirely.
contract DepositPolicy is AccessManaged, GlobalRateLimitedPolicy, Multicall, IDepositPolicy {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    address internal immutable POLICY_APPLIER;

    mapping(address asset => RateLimitBucketLib.Bucket bucket) internal _buckets;

    /// @notice Emitted when an asset's deposit capacity is lowered.
    event DepositCapacityLowered(address indexed asset, uint128 oldCapacity, uint128 newCapacity);

    /// @notice Emitted when an asset's deposit capacity is raised.
    event DepositCapacityRaised(address indexed asset, uint128 oldCapacity, uint128 newCapacity);

    /// @notice Emitted when an asset's deposit refill rate is lowered.
    event DepositRefillRateLowered(address indexed asset, uint128 oldRefillRate, uint128 newRefillRate);

    /// @notice Emitted when an asset's deposit refill rate is raised.
    event DepositRefillRateRaised(address indexed asset, uint128 oldRefillRate, uint128 newRefillRate);

    /// @notice Emitted when the global deposit capacity is lowered.
    event GlobalDepositCapacityLowered(uint128 oldCapacity, uint128 newCapacity);

    /// @notice Emitted when the global deposit capacity is raised.
    event GlobalDepositCapacityRaised(uint128 oldCapacity, uint128 newCapacity);

    /// @notice Emitted when the global deposit refill rate is lowered.
    event GlobalDepositRefillRateLowered(uint128 oldRefillRate, uint128 newRefillRate);

    /// @notice Emitted when the global deposit refill rate is raised.
    event GlobalDepositRefillRateRaised(uint128 oldRefillRate, uint128 newRefillRate);

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
        _consumeGlobalBucket(deposit.asset, deposit.amount);
        emit DepositPolicyApplied(deposit.caller, deposit.user, deposit.asset, deposit.amount);
    }

    /// @inheritdoc IDepositPolicy
    function previewDepositPolicy(DepositIntent calldata deposit) external view override returns (bool) {
        return
            _buckets[deposit.asset].canConsume(deposit.amount) && _canConsumeGlobalBucket(deposit.asset, deposit.amount);
    }

    /// @notice Returns the current deposit-limit bucket for an asset.
    function getDepositLimit(address asset) external view returns (RateLimitBucketLib.Bucket memory) {
        return _buckets[asset];
    }

    /// @notice Raises the deposit capacity for `asset`. Use max uint128 to remove the limit.
    /// @dev Starting with a full bucket, a caller could extract up to `2 * capacity` over
    /// a `capacity / refillRate`-second interval: they can consume the full bucket at the start of the interval and
    /// then match the refill rate for the remaining time. Set `capacity` accordingly.
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

    /// @notice Returns the current global deposit bucket shared across all assets.
    function getGlobalDepositLimit() external view returns (RateLimitBucketLib.Bucket memory) {
        return _globalBucketStorage();
    }

    /// @notice Raises the global deposit capacity. Use max uint128 to remove the limit.
    /// @dev Starting with a full bucket, a caller could extract up to `2 * capacity` over
    /// a `capacity / refillRate`-second interval: they can consume the full bucket at the start of the interval and
    /// then match the refill rate for the remaining time. Set `capacity` accordingly.
    function raiseGlobalDepositCapacity(uint128 newCapacity) external restricted {
        emit GlobalDepositCapacityRaised(_raiseGlobalBucketCapacity(newCapacity), newCapacity);
    }

    /// @notice Lowers the global deposit capacity. `newCapacity = 0` fully rate-limits deposits across all assets.
    function lowerGlobalDepositCapacity(uint128 newCapacity) external restricted {
        emit GlobalDepositCapacityLowered(_lowerGlobalBucketCapacity(newCapacity), newCapacity);
    }

    /// @notice Raises the global deposit refill rate.
    /// @dev Reverts when the global capacity is unlimited, since the rate must stay zero in that case.
    function raiseGlobalDepositRefillRate(uint128 newRefillRate) external restricted {
        emit GlobalDepositRefillRateRaised(_raiseGlobalBucketRefillRate(newRefillRate), newRefillRate);
    }

    /// @notice Lowers the global deposit refill rate. `newRefillRate = 0` stops the refill.
    function lowerGlobalDepositRefillRate(uint128 newRefillRate) external restricted {
        emit GlobalDepositRefillRateLowered(_lowerGlobalBucketRefillRate(newRefillRate), newRefillRate);
    }
}
