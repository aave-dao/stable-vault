// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IAssetRegistry
/// @author Aave Labs
/// @notice Interface for the AssetRegistry contract.
interface IAssetRegistry {
    /// @notice The configuration for an asset.
    /// @param depositFromUserAllowed Whether the asset is allowed to be deposited into the system by a user.
    /// @param withdrawToUserAllowed Whether the asset is allowed to be withdrawn from the system by a user.
    /// @param depositIntoAllocatorAllowed Whether the asset is allowed to be deposited into the Allocator.
    /// @param withdrawFromAllocatorAllowed Whether the asset is allowed to be withdrawn from the Allocator.
    /// @param swapInputTokenAllowed Whether the asset is allowed to be used as swap input token in the Allocator.
    /// @param swapOutputTokenAllowed Whether the asset is allowed to be used as swap output token in the Allocator.
    struct AssetConfig {
        bool depositFromUserAllowed;
        bool withdrawToUserAllowed;
        bool depositIntoAllocatorAllowed;
        bool withdrawFromAllocatorAllowed;
        bool swapInputTokenAllowed;
        bool swapOutputTokenAllowed;
    }

    event AssetConfigSet(address asset, AssetConfig config);

    /// @notice Sets the configuration for an asset.
    /// @param asset Address of the asset to set the configuration for.
    /// @param config Configuration for the asset.
    function setAssetConfig(address asset, AssetConfig memory config) external;

    /// @notice Disables deposits for a given asset.
    /// @dev Separated from `setAssetConfig()` to allow disabling deposits with a different restricted config from
    /// the function which enables deposits.
    /// @param asset Address of the asset to disable deposits for.
    /// @param disableUserDeposits Whether to disable user deposits for the asset.
    /// @param disableAllocatorDeposits Whether to disable allocator deposits for the asset.
    function disableDeposits(address asset, bool disableUserDeposits, bool disableAllocatorDeposits) external;

    /// @notice Getter for whether the asset is allowed to be deposited into the system by a user.
    /// @param asset Address of the asset to check if it is allowed to be deposited into the system by a user.
    /// @return isAllowed Whether the asset is allowed to be deposited into the system by a user.
    function isUserDepositAllowed(address asset) external view returns (bool);

    /// @notice Getter for whether the asset is allowed to be withdrawn from the system by a user.
    /// @param asset Address of the asset to check if it is allowed to be withdrawn from the system by a user.
    /// @return isAllowed Whether the asset is allowed to be withdrawn from the system by a user.
    /// @dev Withdrawals may be executed on either Accounting or Earning chains.
    function isUserWithdrawalAllowed(address asset) external view returns (bool);

    /// @notice Getter for whether the asset is allowed to be deposited into the Allocator.
    /// @dev Deposits into the Allocator are made either during a user deposit, rebalancing, or when funds are received
    /// from another chain.
    /// @param asset Address of the asset to check if it is allowed to be deposited into the Allocator.
    /// @return isAllowed Whether the asset is allowed to be deposited into the Allocator.
    function isDepositToAllocatorAllowed(address asset) external view returns (bool);

    /// @notice Getter for whether the asset is allowed to be withdrawn from the Allocator.
    /// @dev Withdrawals from the Allocator are made either during a user withdrawal or when funds are pushed to another
    /// chain.
    /// @param asset Address of the asset to check if it is allowed to be withdrawn from the Allocator.
    /// @return isAllowed Whether the asset is allowed to be withdrawn from the Allocator.
    function isWithdrawalFromAllocatorAllowed(address asset) external view returns (bool);

    /// @notice Getter for whether the asset is allowed to be used as swap input token from the Allocator into the
    /// Swapper.
    /// @param asset Address of the asset to check if it is allowed to be used as swap input token from the
    /// Allocator into the Swapper.
    /// @return isAllowed Whether the asset is allowed to be used as swap input token from the Allocator into the
    /// Swapper.
    function isSwapInputAllowed(address asset) external view returns (bool);

    /// @notice Getter for whether the asset is allowed to be used as swap output token from the Swapper into the
    /// Allocator.
    /// @param asset Address of the asset to check if it is allowed to be used as swap output token from the
    /// Swapper into the Allocator.
    /// @return isAllowed Whether the asset is allowed to be used as swap output token from the Swapper into the
    /// Allocator.
    function isSwapOutputAllowed(address asset) external view returns (bool);

    /// @notice Getter for the list of all registered assets.
    /// @return assets The list of registered asset addresses.
    function getRegisteredAssets() external view returns (address[] memory);
}
