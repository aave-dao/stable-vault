// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IRescuableAssetNative} from "src/interfaces/IRescuableAssetNative.sol";
import {Errors} from "src/types/Errors.sol";

/// @title RescuableAssetNative
/// @author Aave Labs
/// @notice Abstract base contract for contracts that can rescue native assets.
abstract contract RescuableAssetNative is IRescuableAssetNative {
    /// @inheritdoc IRescuableAssetNative
    function rescueNative(uint256 amount) public virtual override {
        _beforeRescueNative(amount);
        (bool callSucceeded,) = msg.sender.call{value: amount}("");
        require(callSucceeded, Errors.NativeTransferFailed());
    }

    function _beforeRescueNative(uint256 amount) internal virtual;
}
