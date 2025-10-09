// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev Assume 1 strategy per asset; multiple assets per Allocator
/// @dev Deals with assets in their native decimals
interface IAllocator {
    struct AllocatedAssets {
        address asset;
        uint256 amount;
    }

    struct CrossAssetRebalanceParams {
        // Asset to approve the router to spend
        address fromAsset;
        // Amount of fromAsset to approve the router to spend
        uint256 fromAmount;
        // Asset to swap to that will be resupplied within the allocator
        address toAsset;
        // Minimum slippage in basis points (100 = 1%)
        uint16 minSlippageBps;
        // Router to use to swap fromAsset to toAsset
        address router;
        // Selector + Data to pass to the router
        bytes routerData;
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

    function rebalance(CrossAssetRebalanceParams[] memory params) external;

    function setSwapper(address newSwapper) external;

    function setManager(address newManager) external;

    function setDepositor(address depositor, bool whitelisted) external;
}
