// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ISwapper
/// @author Aave Labs
/// @notice Interface for the Swapper contract.
interface ISwapper {
    /// @notice Executes a swap. Encoding of `data` and any slippage / coverage policy is implementation-defined.
    /// @dev The caller must transfer `amountIn` of `assetIn` to the swapper before invocation.
    /// @dev The swapper must approve `amountOut` of `assetOut` to the caller before returning.
    /// @param assetIn Address of the swap input asset.
    /// @param assetOut Address of the asset in which the output of the swap is expected.
    /// @param amountIn Amount of `assetIn` transferred to the swapper.
    /// @param msgSender Address of the original account initiating the swap.
    /// @param data Implementation-specific calldata required by the swapper to execute the swap.
    /// @return amountOut Amount of `assetOut` approved to the caller.
    function executeSwap(address assetIn, address assetOut, uint256 amountIn, address msgSender, bytes memory data)
        external
        returns (uint256 amountOut);
}
