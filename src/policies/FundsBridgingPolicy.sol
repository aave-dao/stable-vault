// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IFundsBridgingPolicy} from "src/interfaces/IFundsBridgingPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {GlobalRateLimitedPolicy} from "src/policies/base/GlobalRateLimitedPolicy.sol";
import {Errors} from "src/types/Errors.sol";

/// @title FundsBridgingPolicy
/// @author Aave Labs
/// @notice Rate-limited bridge-funds policy combining per-route buckets with a global bucket. Each
/// `(asset, destChainId, bridgeAdapter)` triple has its own bucket denominated in the asset's native decimals; the
/// global bucket bounds total throughput across all routes, with amounts normalized to 18 decimals (the maximum
/// supported asset decimals). All buckets default to zero capacity (fully rate-limited) until operator configures
/// them; setting capacity to max uint128 removes the limit entirely.
contract FundsBridgingPolicy is AccessManaged, GlobalRateLimitedPolicy, Multicall, IFundsBridgingPolicy {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    address internal immutable POLICY_APPLIER;

    mapping(
        address asset
            => mapping(uint256 destChainId => mapping(address bridgeAdapter => RateLimitBucketLib.Bucket bucket))
    ) internal _buckets;

    /// @notice Emitted when a bridge route's capacity is lowered.
    event BridgingCapacityLowered(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldCapacity,
        uint128 newCapacity
    );

    /// @notice Emitted when a bridge route's capacity is raised.
    event BridgingCapacityRaised(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldCapacity,
        uint128 newCapacity
    );

    /// @notice Emitted when a bridge route's refill rate is lowered.
    event BridgingRefillRateLowered(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldRefillRate,
        uint128 newRefillRate
    );

    /// @notice Emitted when a bridge route's refill rate is raised.
    event BridgingRefillRateRaised(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldRefillRate,
        uint128 newRefillRate
    );

    /// @notice Emitted when the global bridging capacity is lowered.
    event GlobalBridgingCapacityLowered(uint128 oldCapacity, uint128 newCapacity);

    /// @notice Emitted when the global bridging capacity is raised.
    event GlobalBridgingCapacityRaised(uint128 oldCapacity, uint128 newCapacity);

    /// @notice Emitted when the global bridging refill rate is lowered.
    event GlobalBridgingRefillRateLowered(uint128 oldRefillRate, uint128 newRefillRate);

    /// @notice Emitted when the global bridging refill rate is raised.
    event GlobalBridgingRefillRateRaised(uint128 oldRefillRate, uint128 newRefillRate);

    modifier onlyPolicyApplier() {
        require(msg.sender == POLICY_APPLIER, Errors.NotAuthorized());
        _;
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param fundsBridgingPolicyApplier Address allowed to apply the bridge-funds policy (typically the FundsHandler
    /// on the Accounting Chain or the EarningChainGateway on an Earning Chain).
    constructor(address accessManager, address fundsBridgingPolicyApplier) AccessManaged(accessManager) {
        require(fundsBridgingPolicyApplier != address(0), Errors.ZeroAddress());
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        POLICY_APPLIER = fundsBridgingPolicyApplier;
    }

    /// @inheritdoc IFundsBridgingPolicy
    function applyFundsBridgingPolicy(FundsBridgingIntent calldata fundsBridging) external override onlyPolicyApplier {
        _buckets[fundsBridging.asset][fundsBridging.destChainId][fundsBridging.bridgeAdapter].consume(
            fundsBridging.amount
        );
        _consumeGlobalBucket(fundsBridging.asset, fundsBridging.amount);
        emit FundsBridgingPolicyApplied(
            fundsBridging.caller,
            fundsBridging.bridgeAdapter,
            fundsBridging.destChainId,
            fundsBridging.asset,
            fundsBridging.amount
        );
    }

    /// @inheritdoc IFundsBridgingPolicy
    function previewFundsBridgingPolicy(FundsBridgingIntent calldata fundsBridging)
        external
        view
        override
        returns (bool)
    {
        return _buckets[fundsBridging.asset][fundsBridging.destChainId][fundsBridging.bridgeAdapter].canConsume(
            fundsBridging.amount
        ) && _canConsumeGlobalBucket(fundsBridging.asset, fundsBridging.amount);
    }

    /// @notice Returns the current bridge-funds bucket for the given route.
    function getBridgingLimit(address asset, uint256 destChainId, address bridgeAdapter)
        external
        view
        returns (RateLimitBucketLib.Bucket memory)
    {
        return _buckets[asset][destChainId][bridgeAdapter];
    }

    /// @notice Raises the bridging capacity for a route. Use max uint128 to remove the limit.
    /// @dev Starting with a full bucket, a caller could extract up to `2 * capacity` over
    /// a `capacity / refillRate`-second interval: they can consume the full bucket at the start of the interval and
    /// then match the refill rate for the remaining time. Set `capacity` accordingly.
    function raiseBridgingCapacity(address asset, uint256 destChainId, address bridgeAdapter, uint128 newCapacity)
        external
        restricted
    {
        uint128 oldCapacity = _buckets[asset][destChainId][bridgeAdapter].capacity;
        _buckets[asset][destChainId][bridgeAdapter].raiseCapacity(newCapacity);
        emit BridgingCapacityRaised(asset, destChainId, bridgeAdapter, oldCapacity, newCapacity);
    }

    /// @notice Lowers the bridging capacity for a route. `newCapacity = 0` fully rate-limits the route.
    function lowerBridgingCapacity(address asset, uint256 destChainId, address bridgeAdapter, uint128 newCapacity)
        external
        restricted
    {
        uint128 oldCapacity = _buckets[asset][destChainId][bridgeAdapter].capacity;
        _buckets[asset][destChainId][bridgeAdapter].lowerCapacity(newCapacity);
        emit BridgingCapacityLowered(asset, destChainId, bridgeAdapter, oldCapacity, newCapacity);
    }

    /// @notice Raises the bridging refill rate for a route.
    /// @dev Reverts when the route's capacity is unlimited, since the rate must stay zero in that case.
    function raiseBridgingRefillRate(address asset, uint256 destChainId, address bridgeAdapter, uint128 newRefillRate)
        external
        restricted
    {
        uint128 oldRefillRate = _buckets[asset][destChainId][bridgeAdapter].refillRate;
        _buckets[asset][destChainId][bridgeAdapter].raiseRefillRate(newRefillRate);
        emit BridgingRefillRateRaised(asset, destChainId, bridgeAdapter, oldRefillRate, newRefillRate);
    }

    /// @notice Lowers the bridging refill rate for a route. `newRefillRate = 0` stops the refill.
    function lowerBridgingRefillRate(address asset, uint256 destChainId, address bridgeAdapter, uint128 newRefillRate)
        external
        restricted
    {
        uint128 oldRefillRate = _buckets[asset][destChainId][bridgeAdapter].refillRate;
        _buckets[asset][destChainId][bridgeAdapter].lowerRefillRate(newRefillRate);
        emit BridgingRefillRateLowered(asset, destChainId, bridgeAdapter, oldRefillRate, newRefillRate);
    }

    /// @notice Returns the current global bridging bucket shared across all routes.
    function getGlobalBridgingLimit() external view returns (RateLimitBucketLib.Bucket memory) {
        return _globalBucketStorage();
    }

    /// @notice Raises the global bridging capacity. Use max uint128 to remove the limit.
    /// @dev Starting with a full bucket, a caller could extract up to `2 * capacity` over
    /// a `capacity / refillRate`-second interval: they can consume the full bucket at the start of the interval and
    /// then match the refill rate for the remaining time. Set `capacity` accordingly.
    function raiseGlobalBridgingCapacity(uint128 newCapacity) external restricted {
        emit GlobalBridgingCapacityRaised(_raiseGlobalBucketCapacity(newCapacity), newCapacity);
    }

    /// @notice Lowers the global bridging capacity. `newCapacity = 0` fully rate-limits bridging across all routes.
    function lowerGlobalBridgingCapacity(uint128 newCapacity) external restricted {
        emit GlobalBridgingCapacityLowered(_lowerGlobalBucketCapacity(newCapacity), newCapacity);
    }

    /// @notice Raises the global bridging refill rate.
    /// @dev Reverts when the global capacity is unlimited, since the rate must stay zero in that case.
    function raiseGlobalBridgingRefillRate(uint128 newRefillRate) external restricted {
        emit GlobalBridgingRefillRateRaised(_raiseGlobalBucketRefillRate(newRefillRate), newRefillRate);
    }

    /// @notice Lowers the global bridging refill rate. `newRefillRate = 0` stops the refill.
    function lowerGlobalBridgingRefillRate(uint128 newRefillRate) external restricted {
        emit GlobalBridgingRefillRateLowered(_lowerGlobalBucketRefillRate(newRefillRate), newRefillRate);
    }
}
