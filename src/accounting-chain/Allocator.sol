// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AssetLib} from "../libraries/AssetLib.sol";
import {IAllocator} from "./interfaces/IAllocator.sol";

import {EarningChainRouter} from "./EarningChainRouter.sol";

/// @dev Assume 1 strategy per asset; multiple assets per allocator
/// @dev Deals with assets in their native decimals
contract Allocator is IAllocator {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    modifier onlyWhitelistedDepositor {
        require(_whitelistedDepositor[msg.sender], OnlyDepositor());
        _;
    }

    modifier onlyCommunicationHandler {
        require(msg.sender == address(_communicationHandler), OnlyCommunicationHandler());
        _;
    }


    // TODO: do we need a supported assets mapping/list? Can the allocator receive assets that it must swap from?
    mapping (address asset => address vault) internal _vaultByAsset;
    mapping (address depositor => bool whitelisted) internal _whitelistedDepositor;
    address[] internal _vaults; // TODO: Think how we handle/populate this (when whitelisting probably?)
    EarningChainRouter _communicationHandler; // EarningChainRouter

    function rebalance(CrossAssetRebalanceParams[] memory params) external {
        
    }

    function deposit(address asset, uint256 amount) external onlyWhitelistedDepositor {
        address vault = _vaultByAsset[asset];
        IERC20(asset).forceApprove(vault, amount); // TODO: Review if forceApprove or safeIncreaseAllowance
        uint256 shares = IERC4626(vault).deposit(amount, address(this));
        // TODO: Think what we do with the shares amount - do we save it? return it?
        // return shares;
    }

    function withdraw(address asset, uint256 amount) external onlyCommunicationHandler {
        IERC4626(_vaultByAsset[asset]).withdraw(amount, address(_communicationHandler), address(this));
    }

    /// Request any asset from the allocator for a given amount; assumes allocator assets have common denomination.
    function withdrawEmergency(uint256 amount) external returns (address asset) {
        // TODO: Implement
        return address(0);
    }

    function getAssets() external view returns (IAllocator.AllocatedAssets[] memory) {
        IAllocator.AllocatedAssets[] memory allocatedAssets = new IAllocator.AllocatedAssets[](_vaults.length);
        for (uint256 i = 0; i < _vaults.length; i++) {
            address asset = IERC4626(_vaults[i]).asset();
            uint256 amount = IERC4626(_vaults[i]).maxWithdraw(address(this));
            // TODO: Sum by asset if multiple vaults per asset?
            allocatedAssets[i] = IAllocator.AllocatedAssets(asset, amount);
        }
        return allocatedAssets;
    }

    /// @return amount of total assets in all the vaults in RAY
    function getTotalAssets() external view returns (uint256) {
        uint256 totalAssetsInRay;
        for (uint256 i = 0; i < _vaults.length; i++) {
            uint256 assetAmount = IERC4626(_vaults[i]).maxWithdraw(address(this));
            address asset = IERC4626(_vaults[i]).asset();
            uint256 amountInRay = assetAmount.assetDecimalsToRay(asset);
            totalAssetsInRay += amountInRay;
        }
        return totalAssetsInRay;
    }
}
