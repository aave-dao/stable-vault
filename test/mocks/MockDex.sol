// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

    /// @dev amountOut = netIn * 10^(decOut-decIn) * rateBps / 10_000
    uint16 public rateBps = 10_000;
    // 100% by default (1:1 after decimal scaling)
    uint256 public flatFeeIn;

    function setSlippageBps(uint16 slippageBps) external {
        require(slippageBps <= 10_000, "Slippage must be less than or equal to 100%");
        rateBps = 10_000 - slippageBps;
    }

    /// @dev Set a fixed fee value on the input token
    function setFlatFeeIn(uint256 fee) external {
        flatFeeIn = fee;
    }

    /// @notice Provide tokenOut liquidity (DEX pays from its balance)
    function fund(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 netIn = amountIn > flatFeeIn ? amountIn - flatFeeIn : 0;

        uint8 din = IERC20Metadata(tokenIn).decimals();
        uint8 dout = IERC20Metadata(tokenOut).decimals();

        if (dout >= din) {
            amountOut = netIn * (10 ** (dout - din));
        } else {
            amountOut = netIn / (10 ** (din - dout));
        }

        amountOut = (amountOut * rateBps) / 10_000;
        require(amountOut >= minAmountOut, IMockDex.Slippage());
        require(IERC20(tokenOut).balanceOf(address(this)) >= amountOut, IMockDex.InsufficientLiquidity());

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
