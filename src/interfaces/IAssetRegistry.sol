// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IAssetRegistry {
    struct AssetConfig {
        // Token is able to be deposited into BBV
        bool depositFromUserAllowed;
        // Token is able to be withdrawn from BBV
        bool withdrawToUserAllowed;
        // Token is able to be deposited into Allocator
        bool depositIntoAllocatorAllowed;
        // Token is able to be withdrawn from Allocator
        bool withdrawFromAllocatorAllowed;
        // Token is able to be used as swap input token in the Allocator
        bool swapInputTokenAllowed;
        // Token is able to be used as swap output token in the Allocator
        bool swapOutputTokenAllowed;
    }

    event AssetConfigSet(address asset, AssetConfig config);

    function setAssetConfig(address asset, AssetConfig memory config) external;

    /// @dev Returns if the asset is allowed to be deposited into the system by a user.
    function isUserDepositAllowed(address asset) external returns (bool);

    /// @dev Returns if the asset is allowed to be withdrawn from the system by a user.
    /// @dev Withdrawals may be executed on either Accounting or Earning chains.
    function isUserWithdrawalAllowed(address asset) external returns (bool);

    /// @dev Returns if the asset is allowed to be deposited into the Allocator.
    /// @dev Deposits into the Allocator are made either during a user deposit or when funds are received from another
    /// chain.
    function isDepositToAllocatorAllowed(address asset) external returns (bool);

    /// @dev Returns if the asset is allowed to be withdrawn from the Allocator.
    /// @dev Withdrawals from the Allocator are made either during a user withdrawal or when funds are pushed to another
    /// chain.
    function isWithdrawalFromAllocatorAllowed(address asset) external returns (bool);

    /// @dev Returns if the asset is allowed to be used as swap input token from the Allocator into the Swapper.
    function isSwapInputAllowed(address asset) external returns (bool);

    /// @dev Returns if the asset is allowed to be used as swap output token from the Swapper into the Allocator.
    function isSwapOutputAllowed(address asset) external returns (bool);
}
