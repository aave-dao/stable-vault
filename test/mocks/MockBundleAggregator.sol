// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {EarningChainStateSchemaV1} from "src/periphery/EarningChainStateSchemaV1.sol";

contract MockBundleAggregator {
    uint8[] internal _bundleDecimals;
    uint256 internal _totalBalanceInRay;
    uint256 internal _timestamp;
    uint256 internal _blockNumber;
    uint256 internal _chainId;
    uint256 internal _version;

    function latestBundle() external view returns (bytes memory bundle) {
        require(_version > 0, "Earning chain state version must be set");
        return abi.encode(
            IEarningChainStateProvider.State({
                version: _version,
                data: abi.encode(
                    EarningChainStateSchemaV1.BalanceSnapshot({
                        balanceRay: _totalBalanceInRay,
                        timestamp: _timestamp,
                        blockNumber: _blockNumber,
                        chainId: _chainId
                    })
                )
            })
        );
    }

    function bundleDecimals() external view returns (uint8[] memory decimals) {
        return _bundleDecimals;
    }

    function latestBundleTimestamp() external view returns (uint256 timestamp) {
        return _timestamp;
    }

    function setAnswer(uint256 version, uint256 totalBalanceInRay, uint256 timestamp, uint256 chainId) external {
        _version = version;
        _totalBalanceInRay = totalBalanceInRay;
        _timestamp = timestamp;
        _chainId = chainId;
    }

    function setBundleDecimals(uint8[] memory decimals) external {
        _bundleDecimals = decimals;
    }
}
