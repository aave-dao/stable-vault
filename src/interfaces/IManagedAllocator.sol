// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAllocator} from "./IAllocator.sol";

interface IManagedAllocator is IAllocator {
    struct SwapParams {
        // Swap input asset transferred to swapper
        address assetIn;
        // Asset to swap to that will be resupplied within the allocator
        address assetOut;
        // Amount of assetIn
        uint256 amountIn;
        // Address of the swapper to use to execute the swap
        address swapper;
        // Custom data required by the swapper to execute the swap
        bytes swapData;
    }

    struct CrossAssetRebalanceParams {
        SwapParams[] swaps;
    }

    function depositIdleFunds(address asset) external;

    /// @notice Rebalance the mix of underlying tokens by pulling from strategies, executing swaps and resupplying to
    /// strategies.
    function rebalance(CrossAssetRebalanceParams memory params) external;
}
