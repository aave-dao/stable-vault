// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRescuableAssets} from "src/interfaces/IRescuableAssets.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";

/// @title RescuableAssets
/// @author Aave Labs
/// @notice Abstract base contract for contracts that can rescue tokens.
abstract contract RescuableAssets is IRescuableAssets {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRescuableAssets
    function rescueTokens(address asset, uint256 amount) public virtual override {
        _beforeRescueTokens(asset, amount);
        if (asset == address(0)) {
            (bool callSucceeded,) = msg.sender.call{value: address(this).balance}("");
            require(callSucceeded, ErrorsLib.NativeTransferFailed());
        } else {
            IERC20(asset).safeTransfer(msg.sender, amount);
        }
    }

    function _beforeRescueTokens(address asset, uint256 amount) internal virtual;
}
