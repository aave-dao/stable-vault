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

    struct DeallocationParams {
        address asset;
        address strategy;
        uint256 amount; // Zero amount indicates max deallocation of `asset` from `strategy`
    }

    struct SwapParams {
        address assetIn;
        uint256 amountIn; // TODO: Consider passing zero as wildcard for `amountIn = assetIn.balanceOf(allocator)`
        address assetOut;
        address swapper;
        bytes data; // Custom data that may be required by the swapper to execute the swap
    }

    struct AllocationParams {
        address asset;
        address strategy;
        uint256 amount; // Zero amount indicates max allocation of `asset` balance to `strategy`
    }

    /// @dev A rebalance is a combination of deallocations, swaps, and allocations.
    /// @dev The rebalance will follow a strict order of:
    ///         Step 1. Execute all deallocations in the order specified by the deallocations array.
    ///         Step 2. Execute all swaps in the order specified by the swaps array.
    ///         Step 3. Execute all allocations in the order specified by the allocations array.
    struct RebalanceParams {
        DeallocationParams[] deallocations;
        SwapParams[] swaps;
        AllocationParams[] allocations;
    }

    /// @dev Returns an array of balances where each amount is denominated in the corresponding asset's decimals.
    function getAssetBalances() external view returns (AllocatorBalance[] memory);

    /// @dev Returns yield strategy for a given asset.
    function getDefaultStrategy(address asset) external view returns (address);

    /// @dev Returns if a given strategy is supported for allocating to or deallocating from a given asset.
    function isStrategySupportedForAsset(address asset, address strategy) external view returns (bool);

    /// @dev Returns if a given strategy is supported for allocating or deallocating, regardless of the asset.
    function isStrategySupported(address strategy) external view returns (bool);

    function deposit(address asset, uint256 amount) external;

    /// @notice Rebalances underlying assets.
    /// @dev A rebalance is an ordered combination of the following operations: deallocation of assets from strategies,
    /// swaps between assets, and allocation of assets to strategies.
    function rebalance(RebalanceParams[] memory params) external;

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
