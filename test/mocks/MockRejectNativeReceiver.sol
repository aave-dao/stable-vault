// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

/// @notice Mock contract that rejects plain native currency transfers.
contract MockRejectNativeReceiver {
    receive() external payable {
        revert();
    }
}
