// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AssetLib} from "src/libraries/AssetLib.sol";

interface IMockDex {
    error InsufficientLiquidity();
    error Slippage();

    /// @notice Pulls `amountIn` of tokenIn from msg.sender and transfers amountOut of tokenOut to msg.sender.
    /// @dev msg.sender should be the Swapper in your tests; Swapper must have approved tokenIn to this DEX.
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}

contract MockDex is IMockDex {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    uint256 internal constant MAX_BPS = 10_000;
    uint16 internal _slippageBps = 0;

    function setSlippageBps(uint16 slippageBps) external {
        require(slippageBps <= 10_000, "Slippage must be less than or equal to 100%");
        _slippageBps = slippageBps;
    }

    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = amountIn.convertAssetDecimals(tokenIn, tokenOut);

        amountOut = (amountOut * (MAX_BPS - _slippageBps)) / MAX_BPS;
        require(amountOut >= minAmountOut, IMockDex.Slippage());
        require(IERC20(tokenOut).balanceOf(address(this)) >= amountOut, IMockDex.InsufficientLiquidity());

        uint256 actualAmountOut = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenOut).safeTransfer(msg.sender, actualAmountOut);
        return actualAmountOut;
    }
}
