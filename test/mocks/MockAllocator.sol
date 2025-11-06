// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAllocator} from "../../src/interfaces/IAllocator.sol";

contract MockAllocator is IAllocator {
    using SafeERC20 for IERC20;

    function getAssetBalances() external view override returns (AllocatorBalance[] memory) {}
    function getDefaultVault(address asset) external view override returns (address) {}
    function isVaultSupportedForAsset(address asset, address vault) external view override returns (bool) {}
    function isVaultSupported(address vault) external view override returns (bool) {}
    function deallocate(address asset, uint256 amount, address vault) external override returns (uint256) {}
    function depositIdleFunds(address asset) external override {}
    function deposit(address asset, uint256 amount) external override {}
    function rebalance(CrossAssetRebalanceParams memory params) external override {}
    function reallocate(address asset, uint256 amount, address fromVault, address toVault) external override {}

    function withdraw(address asset, uint256 amount) external override {
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function withdrawFromStrategy(address asset, uint256 amount, address strategyVault) external override {
        (strategyVault);
        IERC20(asset).safeTransfer(msg.sender, amount);
    }
    function addVault(address asset, address vault) external override {}
    function removeVault(address vault) external override {}
    function setDefaultVault(address asset, address vault) external override {}
}
