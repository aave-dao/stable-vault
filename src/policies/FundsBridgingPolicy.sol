// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeFundsPolicy} from "src/interfaces/IBridgeFundsPolicy.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {RateLimitPolicy} from "src/policies/base/RateLimitPolicy.sol";
import {Errors} from "src/types/Errors.sol";

/// @title FundsBridgingPolicy
/// @author Aave Labs
/// @notice Globally rate-limited bridge-funds policy.
/// @dev A single bucket caps the total RAY-scaled amount bridged out across all assets within a refill cycle.
/// Per-asset amounts are normalized via `AssetLib.assetDecimalsToRay` (no price conversion), so each unit of an asset
/// counts the same against the limit regardless of its native decimals. While the bucket holds `capacity == 0`, the
/// policy is unrestricted.
contract FundsBridgingPolicy is RateLimitPolicy, IBridgeFundsPolicy {
    using AssetLib for uint256;

    event BridgingLimitLoosened(uint128 oldCapacity, uint128 oldRefillRate, uint128 newCapacity, uint128 newRefillRate);

    event BridgingLimitTightened(
        uint128 oldCapacity, uint128 oldRefillRate, uint128 newCapacity, uint128 newRefillRate
    );

    address internal immutable POLICY_APPLIER;

    RateLimitBucketLib.Bucket internal _bucket;

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
        _consumeBucket(_bucket, request.amount.assetDecimalsToRay(request.asset));
        emit BridgeFundsPolicyApplied(request.caller, request.destChainId, request.asset, request.amount);
        return true;
    }

    /// @inheritdoc IBridgeFundsPolicy
    function previewBridgeFundsPolicy(BridgeFundsRequest calldata request) external view override returns (bool) {
        return _canConsumeBucket(_bucket, request.amount.assetDecimalsToRay(request.asset));
    }

    /// @notice Returns the current global bridge-funds bucket.
    function getBridgingLimit() external view returns (RateLimitBucketLib.Bucket memory) {
        return _bucket;
    }

    /// @notice Loosens the limit (raises capacity and/or refill rate, or disables it via `capacity = 0`).
    /// @dev Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity` (drain the
    /// full bucket at the start, then match the refill rate). Set `capacity` accordingly.
    function loosenBridgingLimit(uint128 capacity, uint128 refillRate) external restricted {
        (uint128 oldCapacity, uint128 oldRefillRate) = _loosenBucket(_bucket, capacity, refillRate);
        emit BridgingLimitLoosened(oldCapacity, oldRefillRate, capacity, refillRate);
    }

    /// @notice Tightens the limit. Both `capacity` and `refillRate` must be non-increasing and at least one must
    /// strictly decrease; `capacity = 0` (disable) is forbidden here because it would loosen the limit (use
    /// `loosenBridgingLimit`).
    function tightenBridgingLimit(uint128 capacity, uint128 refillRate) external restricted {
        (uint128 oldCapacity, uint128 oldRefillRate) = _tightenBucket(_bucket, capacity, refillRate);
        emit BridgingLimitTightened(oldCapacity, oldRefillRate, capacity, refillRate);
    }
}
