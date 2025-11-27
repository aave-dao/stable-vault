// SPDX-License-Identifier: MIT
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

    /// @notice Returns if the asset is allowed to be deposited into the system by a user.
    function isUserDepositAllowed(address asset) external returns (bool);

    /// @notice Returns if the asset is allowed to be withdrawn from the system by a user.
    /// @dev Withdrawals may be executed on either Accounting or Earning chains.
    function isUserWithdrawalAllowed(address asset) external returns (bool);

    /// @notice Returns if the asset is allowed to be deposited into the Allocator.
    /// @dev Deposits into the Allocator are made either during a user deposit or when funds are received from another
    /// chain.
    function isDepositToAllocatorAllowed(address asset) external returns (bool);

    /// @notice Returns if the asset is allowed to be withdrawn from the Allocator.
    /// @dev Withdrawals from the Allocator are made either during a user withdrawal or when funds are pushed to another
    /// chain.
    function isWithdrawalFromAllocatorAllowed(address asset) external returns (bool);

    /// @notice Returns if the asset is allowed to be used as swap input token from the Allocator into the Swapper.
    function isSwapInputAllowed(address asset) external returns (bool);

    /// @notice Returns if the asset is allowed to be used as swap output token from the Swapper into the Allocator.
    function isSwapOutputAllowed(address asset) external returns (bool);
}
