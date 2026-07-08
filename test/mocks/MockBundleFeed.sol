// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// solhint-disable-next-line interface-starts-with-i
interface IBundleBaseAggregator {
    function latestBundle() external view returns (bytes memory bundle);

    // Not limited to 18 decimals, could be 27?
    function bundleDecimals() external view returns (uint8[] memory);

    function latestBundleTimestamp() external view returns (uint256);
}

/// @title MockBundleFeed
/// @notice Replaces the Chainlink Bundle Aggregator on the Accounting Chain for testing.
/// @dev An operator manually publishes state bytes (read off-chain from EarningChainStateProvider).
contract MockBundleFeed is IBundleBaseAggregator {
    bytes internal _latestBundle;
    uint8[] internal _bundleDecimals;
    uint256 internal _latestBundleTimestamp;

    function latestBundle() external view override returns (bytes memory bundle) {
        return _latestBundle;
    }

    function bundleDecimals() external view override returns (uint8[] memory decimals) {
        return _bundleDecimals;
    }

    function latestBundleTimestamp() external view override returns (uint256 timestamp) {
        return _latestBundleTimestamp;
    }

    function publishState(bytes calldata stateBytes) external {
        _latestBundle = stateBytes;
        _latestBundleTimestamp = block.timestamp;
    }

    function publishStateWithTimestamp(bytes calldata stateBytes, uint256 timestamp) external {
        _latestBundle = stateBytes;
        _latestBundleTimestamp = timestamp;
    }

    function setLatestBundleTimestamp(uint256 timestamp) external {
        _latestBundleTimestamp = timestamp;
    }

    function setBundleDecimals(uint8[] memory decimals) external {
        _bundleDecimals = decimals;
    }
}
