// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeFundsPolicy} from "src/interfaces/IBridgeFundsPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {RateLimitPolicy} from "src/policies/base/RateLimitPolicy.sol";
import {Errors} from "src/types/Errors.sol";

/// @title FundsBridgingPolicy
/// @author Aave Labs
/// @notice Per-route rate-limited bridge-funds policy. Each `(bridgeAdapter, asset, destChainId)` triple has its own
/// bucket; amounts are denominated in the asset's native decimals. A triple without a configured bucket
/// (`capacity == 0`) is unrestricted.
contract FundsBridgingPolicy is RateLimitPolicy, IBridgeFundsPolicy {
    event BridgingLimitLoosened(
        address indexed bridgeAdapter,
        address indexed asset,
        uint256 indexed destChainId,
        uint128 oldCapacity,
        uint128 oldRefillRate,
        uint128 newCapacity,
        uint128 newRefillRate
    );

    event BridgingLimitTightened(
        address indexed bridgeAdapter,
        address indexed asset,
        uint256 indexed destChainId,
        uint128 oldCapacity,
        uint128 oldRefillRate,
        uint128 newCapacity,
        uint128 newRefillRate
    );

    address internal immutable POLICY_APPLIER;

    mapping(
        address bridgeAdapter
            => mapping(address asset => mapping(uint256 destChainId => RateLimitBucketLib.Bucket bucket))
    ) internal _buckets;

    modifier onlyPolicyApplier() {
        require(msg.sender == POLICY_APPLIER, Errors.NotAuthorized());
        _;
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param fundsBridgingPolicyApplier Address allowed to apply the bridge-funds policy (typically the FundsHandler
    /// on the Accounting Chain or the EarningChainGateway on an Earning Chain).
    constructor(address accessManager, address fundsBridgingPolicyApplier) RateLimitPolicy(accessManager) {
        require(fundsBridgingPolicyApplier != address(0), Errors.ZeroAddress());
        POLICY_APPLIER = fundsBridgingPolicyApplier;
    }

    /// @inheritdoc IBridgeFundsPolicy
    function applyBridgeFundsPolicy(BridgeFundsRequest calldata request)
        external
        override
        onlyPolicyApplier
        returns (bool)
    {
        _consumeBucket(_buckets[request.bridgeAdapter][request.asset][request.destChainId], request.amount);
        emit BridgeFundsPolicyApplied(
            request.caller, request.bridgeAdapter, request.destChainId, request.asset, request.amount
        );
        return true;
    }

    /// @inheritdoc IBridgeFundsPolicy
    function previewBridgeFundsPolicy(BridgeFundsRequest calldata request) external view override returns (bool) {
        return _canConsumeBucket(_buckets[request.bridgeAdapter][request.asset][request.destChainId], request.amount);
    }

    /// @notice Returns the current bridge-funds bucket for the given route.
    function getBridgingLimit(address bridgeAdapter, address asset, uint256 destChainId)
        external
        view
        returns (RateLimitBucketLib.Bucket memory)
    {
        return _buckets[bridgeAdapter][asset][destChainId];
    }

    /// @notice Loosens the limit for a route (raises capacity and/or refill rate, or disables it via `capacity = 0`).
    /// @dev Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity` (drain the
    /// full bucket at the start, then match the refill rate). Set `capacity` accordingly.
    function loosenBridgingLimit(
        address bridgeAdapter,
        address asset,
        uint256 destChainId,
        uint128 capacity,
        uint128 refillRate
    ) external restricted {
        (uint128 oldCapacity, uint128 oldRefillRate) =
            _loosenBucket(_buckets[bridgeAdapter][asset][destChainId], capacity, refillRate);
        emit BridgingLimitLoosened(bridgeAdapter, asset, destChainId, oldCapacity, oldRefillRate, capacity, refillRate);
    }

    /// @notice Tightens the limit for a route. Both `capacity` and `refillRate` must be non-increasing and at least
    /// one must strictly decrease; `capacity = 0` (disable) is forbidden here because it would loosen the limit (use
    /// `loosenBridgingLimit`).
    function tightenBridgingLimit(
        address bridgeAdapter,
        address asset,
        uint256 destChainId,
        uint128 capacity,
        uint128 refillRate
    ) external restricted {
        (uint128 oldCapacity, uint128 oldRefillRate) =
            _tightenBucket(_buckets[bridgeAdapter][asset][destChainId], capacity, refillRate);
        emit BridgingLimitTightened(bridgeAdapter, asset, destChainId, oldCapacity, oldRefillRate, capacity, refillRate);
    }
}
