// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IFundsBridgingPolicy} from "src/interfaces/IFundsBridgingPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {Errors} from "src/types/Errors.sol";

/// @title FundsBridgingPolicy
/// @author Aave Labs
/// @notice Per-route rate-limited bridge-funds policy. Each `(asset, destChainId, bridgeAdapter)` triple has its own
/// bucket; amounts are denominated in the asset's native decimals. Triples default to a zero-capacity bucket (fully
/// rate-limited) until operator configures one; setting capacity to max uint128 removes the limit entirely.
contract FundsBridgingPolicy is AccessManaged, Multicall, IFundsBridgingPolicy {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    event BridgingCapacityRaised(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldCapacity,
        uint128 newCapacity
    );
    event BridgingCapacityLowered(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldCapacity,
        uint128 newCapacity
    );
    event BridgingRefillRateRaised(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldRefillRate,
        uint128 newRefillRate
    );
    event BridgingRefillRateLowered(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldRefillRate,
        uint128 newRefillRate
    );

    address internal immutable POLICY_APPLIER;

    mapping(
        address asset
            => mapping(uint256 destChainId => mapping(address bridgeAdapter => RateLimitBucketLib.Bucket bucket))
    ) internal _buckets;

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
        );
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
}
