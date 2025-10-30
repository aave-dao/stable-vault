// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IAssetRegistry {
    struct AssetConfig {
        // Token is able to be deposited into BBV
        bool depositIntoBBVAllowed;
        // Token is able to be withdrawn from BBV
        bool withdrawFromBBVAllowed;
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
    function isAllowedToDepositIntoBBV(address asset) external returns (bool);
    function isAllowedToWithdrawFromBBV(address asset) external returns (bool);
    function isAllowedToDepositIntoAllocator(address asset) external returns (bool);
    function isAllowedToWithdrawFromAllocator(address asset) external returns (bool);
    function isAllowedSwapInputToken(address asset) external returns (bool);
    function isAllowedSwapOutputToken(address asset) external returns (bool);
}
