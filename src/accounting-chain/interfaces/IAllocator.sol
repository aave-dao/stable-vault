// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev Assume 1 strategy per asset; multiple assets per Allocator
/// @dev Deals with assets in their native decimals
interface IAllocator {
    struct AllocatedAssets {
        address asset;
        uint256 amount;
    }

    struct SwapParams {
        // Asset to approve the router to spend
        address fromAsset;
        // Amount of fromAsset to approve the router to spend
        uint256 fromAmount;
        // Asset to swap to that will be resupplied within the allocator
        address toAsset;
        // Slippage tolerance in basis points (100 = 1%)
        uint16 slippageToleranceBps;
        // Swap contract address
        address swapContract;
        // Custom data required by the swapper to execute the swap
        bytes swapData;
    }

    struct CrossAssetRebalanceParams {
        SwapParams[] swaps;
        // Token used to cover slippage and/or fees; Allocator must be approved to spend tokens on behalf of coverageTokenOwner.
        address coverageToken;
        // Owner of the coverage token; Allocator must be approved to spend coverageToken tokens on behalf of coverageTokenOwner.
        address coverageTokenOwner;
    }

    function manager() external view returns (address);

    function admin() external view returns (address);

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
