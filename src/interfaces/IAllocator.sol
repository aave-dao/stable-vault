// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev Assumes single strategy per asset; multiple assets per Allocator.
/// @dev Deals with assets in their native decimals.
interface IAllocator {
    event AssetDeallocated(address indexed asset, address indexed strategy, uint256 amount, uint256 burnedShares);
    /// @notice emitted when funds fails to deposit to yield strategy and left idle in Allocator.
    event StrategyDepositFailed(address indexed strategy, uint256 amount);
    event StrategyAdded(address indexed asset, address indexed strategy);
    event StrategyRemoved(address indexed asset, address indexed strategy);
    event DefaultStrategySet(address indexed asset, address indexed strategy);

    error NonZeroStrategyBalance();
    error FailedToDepositIntoStrategy();

    struct AllocatorBalance {
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

    /// @dev Returns an array of balances where each amount is denominated in the corresponding asset's decimals.
    function getAssetBalances() external view returns (AllocatorBalance[] memory);

    /// @dev Returns yield strategy for a given asset.
    function getDefaultStrategy(address asset) external view returns (address);

    /// @dev Returns if a given strategy is supported for allocating to or deallocating from a given asset.
    function isStrategySupportedForAsset(address asset, address strategy) external view returns (bool);

    /// @dev Returns if a given strategy is supported for allocating or deallocating, regardless of the asset.
    function isStrategySupported(address strategy) external view returns (bool);

    /// @dev Deallocates a given amount of an asset from the immediate liquidity strategy; funds stay idle on the
    /// contract. @param asset Asset to deallocate.
    /// @param amount Amount of the asset to deallocate. Zero to deallocate the maximum possible amount.
    /// @param strategy strategy to deallocate from.
    /// @dev Returns the amount of shares burned liquidity source strategy shares burned.
    function deallocate(address asset, uint256 amount, address strategy) external returns (uint256);

    /// @notice Moves all idle funds of a given asset on the contract to a strategy.
    function depositIdleFunds(address asset) external;

    function deposit(address asset, uint256 amount) external;

    /// @notice Rebalance the mix of underlying tokens by pulling from strategies, executing swaps and resupplying to
    /// strategies.
    /// @dev Swapping is only performed on idle balances or assets in the default yield strategy.
    function rebalance(CrossAssetRebalanceParams memory params) external;

    /// @notice Reallocates a given amount of an asset from one strategy to another.
    /// @param asset Asset to reallocate.
    /// @param amount Amount of the asset expected to be reallocated.
    /// @param fromStrategy strategy to deallocate from.
    /// @param toStrategy strategy to allocate to.
    function reallocate(address asset, uint256 amount, address fromStrategy, address toStrategy) external;

    /// @notice Withdraws a given amount of an asset from the immediate liquidity strategy a.k.a the default strategy
    /// strategy for the asset.
    /// @dev Prioritizes idle funds, default strategy, then non-default strategy(s).
    /// @param asset Asset to withdraw.
    /// @param amount Amount of the asset to withdraw.
    function withdraw(address asset, uint256 amount) external;

    /// @dev Adds a new yield strategy to the allocator.
    /// @param asset The asset to add the strategy for.
    /// @param strategy The ERC-4626 strategy address.
    function addStrategy(address asset, address strategy) external;

    /// @dev Removes a yield strategy from the allocator.
    /// @param strategy The ERC-4626 strategy address to remove.
    function removeStrategy(address strategy) external;

    /// @dev Sets the default yield strategy for an asset.
    /// @param asset The asset to set the default strategy for.
    /// @param strategy The ERC-4626 strategy address to set as the default.
    function setDefaultStrategy(address asset, address strategy) external;
}
