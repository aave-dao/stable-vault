// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.0;

import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";

contract RateLimitBucketLibWrapper {
    using RateLimitBucketLib for RateLimitBucketLib.Bucket;

    RateLimitBucketLib.Bucket internal _bucket;

    function preview() external view returns (uint256) {
        return _bucket.preview();
    }

    function consume(uint256 amount) external {
        _bucket.consume(amount);
    }

    function canConsume(uint256 amount) external view returns (bool) {
        return _bucket.canConsume(amount);
    }

    function configure(uint128 capacity, uint128 refillRate) external {
        _bucket.configure(capacity, refillRate);
    }

    function getBucket() external view returns (RateLimitBucketLib.Bucket memory) {
        return _bucket;
    }

    function unlimitedCapacity() external pure returns (uint256) {
        return RateLimitBucketLib.UNLIMITED_CAPACITY;
    }
}
