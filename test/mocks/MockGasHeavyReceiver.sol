// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

/// @notice Mock contract that consumes more than 2300 gas in its receive() function,
/// simulating a Gnosis Safe or similar smart contract wallet.
/// @dev Gnosis Safe's fallback handler performs SLOAD + DELEGATECALL on receive(),
/// which costs well above the 2300 gas stipend provided by .transfer().
contract MockGasHeavyReceiver {
    uint256 private _receivedCount;
    uint256 private _lastValue;

    receive() external payable {
        // Simulate Safe-like gas-heavy receive: SSTORE costs 5000+ gas, far exceeding the 2300 stipend.
        _receivedCount += 1;
        _lastValue = msg.value;
    }

    function receivedCount() external view returns (uint256) {
        return _receivedCount;
    }

    function lastValue() external view returns (uint256) {
        return _lastValue;
    }
}
