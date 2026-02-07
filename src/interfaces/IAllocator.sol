// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IAllocator
/// @author Aave Labs
/// @notice Interface for the Allocator contract.
interface IAllocator {
    event AssetAllocated(address indexed asset, address indexed strategy, uint256 amount, uint256 netDepositAmount);

    event AssetDeallocated(address indexed asset, address indexed strategy, uint256 amount);

    event AssetLeftIdle(address indexed asset, uint256 amount);

    event AssetsSwapped(address indexed assetIn, address indexed assetOut, uint256 amountIn, uint256 amountOut);

    event DefaultStrategySet(address indexed asset, address indexed strategy);

    event StrategyDepositFailed(address indexed strategy, uint256 amount);

    event StrategyDepositsToggled(address indexed strategy, bool depositsEnabled);

    event StrategyWithdrawalFailed(address indexed strategy, address indexed asset, uint256 amount);

    event StrategyAdded(address indexed asset, address indexed strategy, uint8 maxSlippageAmount);

    event StrategyRemoved(address indexed asset, address indexed strategy);

    /// @notice Thrown when setting as default a strategy that already is the default, or when removing a strategy
    /// that is currently set as the default.
    /// @custom:selector 0x13e93f82
    error DefaultStrategy(address strategy);

    /// @notice Thrown when funds fail to deposit into a yield strategy.
    /// @custom:selector 0x3868bf52
    error DepositIntoStrategyFailed(address strategy);

    /// @notice Thrown when deposits are not allowed to a strategy.
    /// @custom:selector 0xd7b75095
    error DepositsToStrategyDisabled(address strategy);

    /// @notice Thrown when a strategy still has assets that belong to the Allocator.
    /// @custom:selector 0xa01adeda
    error StrategyStillHasFunds(address strategy);

    /// @notice Thrown when the maximum number of strategies per asset is exceeded.
    /// @custom:selector 0x83864c08
    error TooManyStrategies(address asset);

    /// @notice The representation of an asset balance.
    /// @param asset Address of the asset.
    /// @param amount Amount of the asset.
    struct AllocatorBalance {
        // TODO: consider adding value here to reflect the price adjusted value alone (keep the amount)
        address asset;
        uint256 amount;
    }

    /// @notice The parameters for a deallocation.
    /// @param asset Address of the asset to deallocate.
    /// @param strategy Address of the strategy to deallocate from.
    /// @param amount Amount of the asset to deallocate (zero amount indicates max deallocation of `asset` from
    /// `strategy`).
    struct DeallocationParams {
        address asset;
        address strategy;
        uint256 amount;
    }

    /// @notice The parameters for a swap.
    /// @param assetIn Address of the asset to swap from.
    /// @param amountIn Amount of the asset to swap from.
    /// @param assetOut Address of the asset to swap to.
    /// @param swapper Address of the swapper contract.
    /// @param data Custom data that may be required by the swapper to execute the swap.
    struct SwapParams {
        address assetIn;
        uint256 amountIn;
        address assetOut;
        address swapper;
        bytes data;
    }

    /// @notice The parameters for an allocation.
    /// @param asset Address of the asset to allocate.
    /// @param strategy Address of the strategy to allocate to.
    /// @param amount Amount of the asset to allocate (zero amount indicates max allocation of `asset` balance to
    /// `strategy`).
    struct AllocationParams {
        address asset;
        address strategy;
        uint256 amount;
    }

    /// @notice The parameters for a rebalance which is an ordered combination of deallocations, swaps, and allocations.
    /// @param deallocations Array of deallocation parameters.
    /// @param swaps Array of swap parameters.
    /// @param allocations Array of allocation parameters.
    /// @dev The rebalance will follow a strict order of:
    ///         Step 1. Execute all deallocations in the order specified by the deallocations array.
    ///         Step 2. Execute all swaps in the order specified by the swaps array.
    ///         Step 3. Execute all allocations in the order specified by the allocations array.
    struct RebalanceParams {
        DeallocationParams[] deallocations;
        SwapParams[] swaps;
        AllocationParams[] allocations;
    }

    /// @notice The configuration for a strategy.
    /// @param asset The asset that the strategy is associated with (assumes 1 asset per strategy).
    /// @param maxSlippageAmount The maximum amount of slippage allowed for the strategy denominated in the underlying
    /// asset. This value is expected to be in the 1:10 wei range.
    /// @param isRegistered Boolean indicating whether the strategy is configured.
    /// @param depositAllowed Boolean indicating whether the strategy is allowed to be deposited into.
    struct StrategyConfig {
        address asset;
        uint8 maxSlippageAmount;
        bool isRegistered;
        bool depositAllowed;
    }

    /// @notice Getter for the balance of a given asset on the Allocator.
    /// @param asset Address of the asset to get the balance of.
    /// @return balance Balance of the asset in asset decimals in the Allocator (idle + aggregate balance in
    /// strategies).
    function getAssetBalance(address asset) external view returns (uint256);

    /// @notice Getter for the balance of a given strategy on the Allocator.
    /// @param strategy Address of the strategy to get the balance of.
    /// @return balance Balance of tokens in the strategy in asset decimals (assumes one asset per strategy).
    function getAssetBalanceInStrategy(address strategy) external view returns (uint256);

    /// @notice Getter for the balances on the Allocator.
    /// @return balances Array of balances where each amount is denominated in the corresponding asset's decimals.
    function getTrustedAssetBalances() external view returns (AllocatorBalance[] memory balances);

    /// @notice Getter for the default strategy for a given asset.
    /// @param asset Address of the asset to get the default strategy for.
    /// @return strategy Address of the default strategy for the asset.
    function getDefaultStrategy(address asset) external view returns (address);

    /// @notice Getter for the configuration of a given strategy.
    /// @param strategy Address of the strategy to get the configuration for.
    /// @dev Updating the maxSlippageAmount requires removing the strategy then re-adding it with the new
    /// maxSlippageAmount (subject to a timelock).
    /// @return config Configuration of the strategy.
    function getStrategyConfig(address strategy) external view returns (StrategyConfig memory);

    /// @notice Getter for whether a strategy is supported for a given asset.
    /// @param asset Address of the asset to check if the strategy is supported for.
    /// @param strategy Address of the strategy to check if it is supported for the asset.
    /// @return isSupported Whether the strategy is supported for the asset.
    function isStrategySupportedForAsset(address asset, address strategy) external view returns (bool);

    /// @notice Getter for whether a strategy is supported for allocating or deallocating, regardless of the asset.
    /// @param strategy Address of the strategy to check if it is supported for allocating or deallocating.
    /// @return isSupported Whether the strategy is supported for allocating or deallocating.
    function isStrategySupported(address strategy) external view returns (bool);

    /// @notice Deposits a given amount of an asset into the default strategy for the asset.
    /// @param asset Address of the asset to deposit.
    /// @param amount Amount of the asset to deposit.
    /// @return netDepositAmount Amount of the asset deposited after accounting for slippage.
    function deposit(address asset, uint256 amount) external returns (uint256 netDepositAmount);

    /// @notice Deposits a given amount of an asset into the default strategy for the asset, allowing idle funds if the
    /// deposit fails.
    /// @dev This function is to allow funds being bridged to the local chain to be kept in the Allocator
    /// even during error scenarios.
    /// @param asset Address of the asset to deposit.
    /// @param amount Amount of the asset to deposit.
    function depositAllowIdle(address asset, uint256 amount) external;

    /// @notice Rebalances underlying assets.
    /// @dev A rebalance is an ordered combination of the following operations: deallocation of assets from strategies,
    /// swaps between assets, and allocation of assets to strategies.
    /// @param params Array of rebalance parameters.
    function rebalance(RebalanceParams[] memory params) external;

    /// @notice Withdraws a given amount of an asset from the default strategy for the given asset.
    /// @dev Prioritizes idle funds, default strategy, then non-default strategy(s).
    /// @param asset Address of the asset to withdraw.
    /// @param amount Amount of the asset to withdraw.
    function withdraw(address asset, uint256 amount) external;

    /// @notice Adds a new yield strategy to the allocator.
    /// @param asset Address of the asset to add the strategy for.
    /// @param strategy Address of the ERC-4626 strategy to add.
    /// @param maxSlippageAmount The maximum amount of slippage allowed for the strategy denominated in the underlying
    /// asset.
    function addStrategy(address asset, address strategy, uint8 maxSlippageAmount) external;

    /// @notice Removes a yield strategy from the allocator.
    /// @param strategy Address of the ERC-4626 strategy to remove.
    function removeStrategy(address strategy) external;

    /// @notice Sets the default yield strategy for an asset.
    /// @param asset Address of the asset to set the default strategy for.
    /// @param strategy Address of the ERC-4626 strategy to set as the default.
    function setDefaultStrategy(address asset, address strategy) external;

    /// @notice Disables deposits to a given strategy.
    /// @param strategy Address of the ERC-4626 strategy to disable deposits for.
    function disableDepositsToStrategy(address strategy) external;

    /// @notice Enables deposits to a given strategy.
    /// @param strategy Address of the ERC-4626 strategy to enable deposits for.
    function enableDepositsToStrategy(address strategy) external;
}
