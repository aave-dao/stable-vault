// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ISwapper} from "./interfaces/ISwapper.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title Swapper
/// @notice Executes swaps through approved routers and selectors with slippage & access control.
contract Swapper is ISwapper, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc ISwapper
    function executeSwap(
        address, /* fromAsset */
        uint256 fromAmount,
        address toAsset,
        // uint256 expectedAmount,
        uint16 slippageToleranceBps,
        bytes memory data
    ) external nonReentrant returns (uint256) {
        // Assume `fromAmount` tokens of `fromAsset` were sent from the msg.sender

        (address[] memory targets, bytes[] memory callDatas) = abi.decode(data, (address[], bytes[]));

        for (uint256 i = 0; i < targets.length; i++) {
            (bool callSucceeded,) = targets[i].call(callDatas[i]);
            require(callSucceeded);
        }

        uint256 toAmount = IERC20(toAsset).balanceOf(address(this));

        // Slippage check
        // TODO: this is assuming 1:1 swap, check if is needed or not. Maybe expectedAmount can be passed in?
        // TODO: Use AssetLib for comparison taking into account assets' decimals
        uint256 expectedMinOut = (fromAmount * (10_000 - slippageToleranceBps)) / 10_000;
        require(toAmount >= expectedMinOut);

        // Approve funds to be pulled by the caller
        IERC20(toAsset).forceApprove(msg.sender, toAmount);

        return toAmount;
    }
}
