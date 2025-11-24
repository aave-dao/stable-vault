// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ISwapper {
    /// @notice Thrown when the amount of `assetOut` received is less than the minimum amount out expected after a swap.
    error SlippageToleranceExceeded();
    /// @notice Thrown when a low-level call to a target contract is unsuccessful.
    error CallToTargetFailed();

    /// @dev The Swapper must get `fromAmount` of `fromAsset` transferred before the `executeSwap` function is invoked.
    /// @dev The Swapper must approve `amountOut` of `toAsset` to be pulled by msg.sender at the end of `executeSwap`
    /// function execution.
    /// @param assetIn the asset transferred to the swapper
    /// @param assetOut the asset transferred to the msg
    /// @param amountIn the amount of `assetIn` transferred to the swapper
    /// @param data custom data required by the swapper to execute the swap
    /// @return amountOut of `assetOut` that must be approved to be pulled by the msg.sender after returning control of
    /// the execution
    function executeSwap(address assetIn, address assetOut, uint256 amountIn, bytes memory data)
        external
        returns (uint256 amountOut);
}
