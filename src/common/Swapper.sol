// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ISwapper} from "../interfaces/ISwapper.sol";
import {AssetLib} from "../libraries/AssetLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Swapper
/// @notice Executes swaps through approved routers and selectors with slippage & access control.
contract Swapper is ISwapper, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    uint256 constant MAX_BPS = 10_000;

    constructor(address owner) Ownable(owner) {}

    struct SlippageParams {
        uint16 slippageToleranceBps;
        address slippageCoverageSource;
    }

    /// @inheritdoc ISwapper
    function executeSwap(address assetIn, address assetOut, uint256 amountIn, bytes memory data)
        external
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        // Assumes `amountIn` tokens of `assetIn` were sent from the msg.sender

        // TODO: Consider using Multicall's Call struct, allowing calls to fail and adding a msgValue param too
        (address[] memory targets, bytes[] memory callDatas, SlippageParams memory slippageParams) =
            abi.decode(data, (address[], bytes[], SlippageParams));

        for (uint256 i = 0; i < targets.length; i++) {
            (bool callSucceeded,) = targets[i].call(callDatas[i]);
            require(callSucceeded);
        }

        uint256 amountOut = IERC20(assetOut).balanceOf(address(this));

        // We want 1:1 swaps
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(assetIn, assetOut);
        if (amountOut < expectedAmountOut) {
            uint256 slippageAmount = expectedAmountOut - amountOut;
            require(slippageAmount <= amountOut * slippageParams.slippageToleranceBps / MAX_BPS);
            IERC20(assetOut).safeTransferFrom(slippageParams.slippageCoverageSource, address(this), slippageAmount);
        }

        // Approve funds to be pulled by the caller
        IERC20(assetOut).forceApprove(msg.sender, amountOut);

        return amountOut;
    }
}
