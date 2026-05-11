// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IFundsBridgingPolicy} from "src/interfaces/IFundsBridgingPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {RateLimitPolicy} from "src/policies/base/RateLimitPolicy.sol";
import {Errors} from "src/types/Errors.sol";

/// @title FundsBridgingPolicy
/// @author Aave Labs
/// @notice Per-route rate-limited bridge-funds policy. Each `(asset, destChainId, bridgeAdapter)` triple has its own
/// bucket; amounts are denominated in the asset's native decimals. Triples default to a zero-capacity bucket (fully
/// rate-limited) until governance configures one; setting capacity to max uint128 removes the limit entirely.
contract FundsBridgingPolicy is RateLimitPolicy, IFundsBridgingPolicy {
    event BridgingLimitLoosened(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldCapacity,
        uint128 oldRefillRate,
        uint128 newCapacity,
        uint128 newRefillRate
    );

    event BridgingLimitTightened(
        address indexed asset,
        uint256 indexed destChainId,
        address indexed bridgeAdapter,
        uint128 oldCapacity,
        uint128 oldRefillRate,
        uint128 newCapacity,
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
    constructor(address accessManager, address fundsBridgingPolicyApplier) RateLimitPolicy(accessManager) {
        require(fundsBridgingPolicyApplier != address(0), Errors.ZeroAddress());
        POLICY_APPLIER = fundsBridgingPolicyApplier;
    }

    /// @inheritdoc IFundsBridgingPolicy
    function applyFundsBridgingPolicy(FundsBridgingIntent calldata fundsBridging) external override onlyPolicyApplier {
        _consumeBucket(
            _buckets[fundsBridging.asset][fundsBridging.destChainId][fundsBridging.bridgeAdapter], fundsBridging.amount
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
        return _canConsumeBucket(
            _buckets[fundsBridging.asset][fundsBridging.destChainId][fundsBridging.bridgeAdapter], fundsBridging.amount
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

    /// @notice Loosens the limit for a route (raises capacity and/or refill rate, or removes it by setting
    /// `capacity` to max uint128).
    /// @dev Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity` (drain the
    /// full bucket at the start, then match the refill rate). Set `capacity` accordingly.
    function loosenBridgingLimit(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint128 capacity,
        uint128 refillRate
    ) external restricted {
        (uint128 oldCapacity, uint128 oldRefillRate) =
            _loosenBucket(_buckets[asset][destChainId][bridgeAdapter], capacity, refillRate);
        emit BridgingLimitLoosened(asset, destChainId, bridgeAdapter, oldCapacity, oldRefillRate, capacity, refillRate);
    }

    /// @notice Tightens the limit for a route. Both `capacity` and `refillRate` must be non-increasing and at least
    /// one must strictly decrease. `capacity = 0` (fully rate-limited) is allowed as a maximal tighten; max uint128
    /// is forbidden because it would loosen (use `loosenBridgingLimit`).
    function tightenBridgingLimit(
        address asset,
        uint256 destChainId,
        address bridgeAdapter,
        uint128 capacity,
        uint128 refillRate
    ) external restricted {
        (uint128 oldCapacity, uint128 oldRefillRate) =
            _tightenBucket(_buckets[asset][destChainId][bridgeAdapter], capacity, refillRate);
        emit BridgingLimitTightened(asset, destChainId, bridgeAdapter, oldCapacity, oldRefillRate, capacity, refillRate);
    }
}
