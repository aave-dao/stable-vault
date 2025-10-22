// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IAssetRegistry {
    event AssetConfigSet(address asset, uint256 config);

    function isAllowedToDepositIntoBBV(address asset) external returns (bool);
    function isAllowedToWithdrawFromBBV(address asset) external returns (bool);
    function isAllowedToDepositIntoAllocator(address asset) external returns (bool);
    function isAllowedToWithdrawFromAllocator(address asset) external returns (bool);
    function isAllowedSwapInputToken(address asset) external returns (bool);
    function isAllowedSwapOutputToken(address asset) external returns (bool);
}
