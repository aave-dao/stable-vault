// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev Assumes single strategy per asset; multiple assets per Allocator
/// @dev Deals with assets in their native decimals
interface IAllocator {
    struct AllocatedAssets {
        address asset;
        uint256 amount;
    }

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

    function getManager() external view returns (address);

    function getAdmin() external view returns (address);

    function getAssets() external view returns (AllocatedAssets[] memory);

    /// @dev returns latest total assets in strategies denominated in RAY
    function getTotalAssets() external view returns (uint256);

    function deposit(address asset, uint256 amount) external;

    function withdraw(address asset, uint256 amount) external;

    /// Request any asset from the allocator for a given amount; assumes allocator assets have common denomination.
    function withdrawEmergency(uint256 amount) external returns (address asset);

    /// @notice Rebalance the mix of underlying tokens by pulling from strategies, executing swaps and resupplying to strategies.
    function rebalance(CrossAssetRebalanceParams memory params) external;

    function setManager(address newManager) external;

    function setDepositor(address depositor, bool whitelisted) external;
}
