// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ISwapper
/// @author Aave Labs
/// @notice Interface for the Swapper contract.
interface ISwapper {
    /// @notice Emitted when a slippage shortfall on `assetOut` is covered by an external source.
    event SlippageCovered(address indexed slippageCoverageSource, address indexed assetOut, uint256 amount);

    /// @notice Emitted when unconsumed `assetIn` is pushed to an external destination.
    event AssetInSwept(address indexed to, address indexed asset, uint256 amount);

    /// @notice Thrown when a target invariant required by the implementation is violated.
    /// @custom:selector 0x13496fda
    error BadTarget();

    /// @notice Thrown when an implementation-specific subcall fails.
    /// @custom:selector 0x7f1f16cd
    error CallToTargetFailed();

    /// @notice Thrown when the amount of `assetOut` received is below the minimum acceptable amount.
    /// @custom:selector 0x6728a9f6
    error SlippageToleranceExceeded();

    /// @notice Thrown when the requested slippage tolerance exceeds the on-chain bound.
    /// @custom:selector 0x232b3058
    error SlippageToleranceTooHigh();

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
