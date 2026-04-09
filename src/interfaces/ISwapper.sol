// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ISwapper
/// @author Aave Labs
/// @notice Interface for the Swapper contract.
interface ISwapper {
    /// @notice Thrown when the amount of `assetOut` received is less than the minimum amount out expected after a swap.
    /// @custom:selector 0x6728a9f6
    error SlippageToleranceExceeded();

    /// @notice Thrown when a low-level call to a target contract is unsuccessful.
    /// @custom:selector 0x7f1f16cd
    error CallToTargetFailed();

    /// @notice Executes a swap using arbitrary data which can represent a series of calls to one or more contracts.
    /// @dev The Swapper must get `amountIn` of `assetIn` transferred before the `executeSwap` function is invoked.
    /// @dev The Swapper must approve `amountOut` of `assetOut` to be pulled by msg.sender at the end of `executeSwap`
    /// function execution.
    /// @param assetIn Address of the swap input asset, transferred to the swapper before invoking this function.
    /// @param assetOut Address of the asset in which the output of the swap is expected.
    /// @param amountIn Amount of `assetIn` transferred to the swapper.
    /// @param msgSender Address of the original account initiating the swap.
    /// @param data Custom data required by the swapper to execute the swap.
    /// @return amountOut Amount of `assetOut` that must be approved to be pulled by the msg.sender after returning
    /// control of the execution of the swap.
    function executeSwap(address assetIn, address assetOut, uint256 amountIn, address msgSender, bytes memory data)
        external
        returns (uint256 amountOut);
}
