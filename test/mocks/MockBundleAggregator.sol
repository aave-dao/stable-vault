// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainGateway} from "src/interfaces/IChainGateway.sol";

contract MockBundleAggregator {
    uint8[] internal _bundleDecimals;
    uint256 internal _totalBalanceInRay;
    uint256 internal _timestamp;

    function latestBundle() external view returns (bytes memory bundle) {
        return abi.encode(IChainGateway.BalanceSnapshot({totalBalanceInRay: _totalBalanceInRay, timestamp: _timestamp}));
    }

    function bundleDecimals() external view returns (uint8[] memory decimals) {
        return _bundleDecimals;
    }

    function latestBundleTimestamp() external view returns (uint256 timestamp) {
        return _timestamp;
    }

    function setAnswer(uint256 totalBalanceInRay, uint256 timestamp) external {
        _totalBalanceInRay = totalBalanceInRay;
        _timestamp = timestamp;
    }

    function setBundleDecimals(uint8[] memory decimals) external {
        _bundleDecimals = decimals;
    }
}
