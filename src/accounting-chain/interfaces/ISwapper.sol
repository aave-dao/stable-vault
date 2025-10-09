// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ISwapper {
    /// @dev The Swapper must get `fromAmount` of `fromAsset` transferred before the `executeSwap` function is invoked.
    /// @dev The Swapper must approve `toAmount` of `toAsset` to be pulled by msg.sender at the end of `executeSwap` function execution.
    /// @param fromAsset the asset transferred to the swapper
    /// @param fromAmount the amount of `fromAsset` transferred to the swapper
    /// @param toAsset the asset to swap to
    /// @param slippageToleranceBps the minimum slippage in basis points (100 = 1%)
    /// @param data the selector + data to pass to the router
    /// @return toAmount the amount of `toAsset` that must be approved to be pulled by the msg.sender after returning control of the execution
    function executeSwap(
        address fromAsset,
        uint256 fromAmount,
        address toAsset,
        uint16 slippageToleranceBps,
        bytes memory data
    ) external returns (uint256 toAmount);
}
