// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAllocator} from "../../src/interfaces/IAllocator.sol";

contract MockAllocator is IAllocator {
    function getManager() external view override returns (address) {}
    function getAdmin() external view override returns (address) {}
    function getAssetBalances() external view override returns (AllocatorBalance[] memory) {}
    function getAssetBalance(address asset) external view override returns (uint256) {}
    function getDefaultVault(address asset) external view override returns (address) {}
    function isVaultSupportedForAsset(address asset, address vault) external view override returns (bool) {}
    function isVaultSupported(address vault) external view override returns (bool) {}
    function deallocate(address asset, uint256 amount, address vault) external override returns (uint256) {}
    function depositIdleFunds(address asset) external override {}
    function deposit(address asset, uint256 amount) external override {}
    function rebalance(CrossAssetRebalanceParams memory params) external override {}
    function reallocate(address asset, uint256 amount, address fromVault, address toVault) external override {}
    function withdraw(address asset, uint256 amount) external override {}
    function setManager(address newManager) external override {}
    function setDepositor(address depositor, bool whitelisted) external override {}
    function setWithdrawer(address withdrawer, bool whitelisted) external override {}
    function setVault(address asset, address vault, bool isAllowed) external override {}
    function setDefaultVault(address asset, address vault) external override {}
}
