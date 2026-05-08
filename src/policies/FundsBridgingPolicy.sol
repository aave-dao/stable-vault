// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IBridgeFundsPolicy} from "src/interfaces/IBridgeFundsPolicy.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {Errors} from "src/types/Errors.sol";

/// @title FundsBridgingPolicy
/// @author Aave Labs
/// @notice Globally rate-limited bridge-funds policy. A single bucket caps the total RAY-scaled amount bridged
/// out across all assets within a refill cycle. Per-asset amounts are normalized via
/// `AssetLib.assetDecimalsToRay` (no price conversion), so each unit of an asset counts the same against the
/// limit regardless of its native decimals. While the bucket holds `capacity == 0`, the policy is unrestricted.
contract FundsBridgingPolicy is AccessManaged, IBridgeFundsPolicy {
    using AssetLib for uint256;
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    /// @notice Public-facing snapshot of the global bridge-funds limit.
    /// @param capacity Maximum RAY-scaled amount drainable from a fully-refilled bucket.
    /// @param refillRate Per-second amount of capacity restored, in RAY.
    /// @param available Capacity available at `block.timestamp`, refilled but not written back. `0` for an
    /// unconfigured policy (`capacity == 0`).
    struct BridgingLimit {
        uint128 capacity;
        uint128 refillRate;
        uint128 available;
    }

    event BridgingLimitLoosened(uint128 oldCapacity, uint128 oldRefillRate, uint128 newCapacity, uint128 newRefillRate);

    event BridgingLimitTightened(
        uint128 oldCapacity, uint128 oldRefillRate, uint128 newCapacity, uint128 newRefillRate
    );

    address internal immutable FUNDS_BRIDGING_POLICY_APPLIER;

    RateLimitBucketLib.Bucket internal _bucket;

    modifier onlyFundsBridgingPolicyApplier() {
        require(msg.sender == FUNDS_BRIDGING_POLICY_APPLIER, Errors.NotAuthorized());
        _;
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param fundsBridgingPolicyApplier Address allowed to apply the bridge-funds policy (typically the FundsHandler
    /// on the Accounting Chain or the EarningChainGateway on an Earning Chain).
    constructor(address accessManager, address fundsBridgingPolicyApplier) AccessManaged(accessManager) {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        require(fundsBridgingPolicyApplier != address(0), Errors.ZeroAddress());
        FUNDS_BRIDGING_POLICY_APPLIER = fundsBridgingPolicyApplier;
    }

    /// @inheritdoc IBridgeFundsPolicy
    function applyBridgeFundsPolicy(BridgeFundsRequest calldata request)
        external
        override
        onlyFundsBridgingPolicyApplier
        returns (bool)
    {
        if (_bucket.capacity != 0) {
            _bucket.consume(request.amount.assetDecimalsToRay(request.asset));
        }
        emit BridgeFundsPolicyApplied(request.caller, request.destChainId, request.asset, request.amount);
        return true;
    }

    /// @inheritdoc IBridgeFundsPolicy
    function previewBridgeFundsPolicy(BridgeFundsRequest calldata request) external view override returns (bool) {
        if (_bucket.capacity == 0) {
            return true;
        }
        return _bucket.preview() >= request.amount.assetDecimalsToRay(request.asset);
    }

    /// @notice Returns the current global bridge-funds limit.
    function getBridgingLimit() external view returns (BridgingLimit memory) {
        return BridgingLimit({
            capacity: _bucket.capacity,
            refillRate: _bucket.refillRate,
            available: _bucket.capacity == 0 ? 0 : uint128(_bucket.preview())
        });
    }

    /// @notice Loosens the limit (raises capacity and/or refill rate, or disables it via `capacity = 0`).
    /// @dev Over any `capacity / refillRate`-second interval, a caller can extract up to `2 * capacity` (drain the
    /// full bucket at the start, then match the refill rate). Set `capacity` accordingly.
    function loosenBridgingLimit(uint128 capacity, uint128 refillRate) external restricted {
        uint128 oldCapacity = _bucket.capacity;
        uint128 oldRefillRate = _bucket.refillRate;
        // `capacity == 0` disables the limit (maximal loosening); otherwise at least one dimension must strictly
        // increase. Same-or-tighter changes belong on `tightenBridgingLimit`.
        require(capacity == 0 || capacity > oldCapacity || refillRate > oldRefillRate, Errors.InvalidParameter());
        _bucket.configure(capacity, refillRate);
        emit BridgingLimitLoosened(oldCapacity, oldRefillRate, capacity, refillRate);
    }

    /// @notice Tightens the limit. Both `capacity` and `refillRate` must be non-increasing and at least one must
    /// strictly decrease; `capacity = 0` (disable) is forbidden here because it would loosen the limit (use
    /// `loosenBridgingLimit`).
    function tightenBridgingLimit(uint128 capacity, uint128 refillRate) external restricted {
        require(capacity > 0, Errors.InvalidParameter());
        uint128 oldCapacity = _bucket.capacity;
        uint128 oldRefillRate = _bucket.refillRate;
        require(
            capacity <= oldCapacity && refillRate <= oldRefillRate
                && (capacity < oldCapacity || refillRate < oldRefillRate),
            Errors.InvalidParameter()
        );
        _bucket.configure(capacity, refillRate);
        emit BridgingLimitTightened(oldCapacity, oldRefillRate, capacity, refillRate);
    }
}
