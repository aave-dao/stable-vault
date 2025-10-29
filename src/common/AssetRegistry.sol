// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

contract AssetRegistry is Ownable, IAssetRegistry {
    mapping(address asset => AssetConfig config) internal _configByAsset;

    constructor(address owner) Ownable(owner) {}

    function setAssetConfig(address asset, AssetConfig memory config) external onlyOwner {
        _configByAsset[asset] = config;
        emit AssetConfigSet(asset, config);
    }

    // /////////////////////// PERMISSION SPECIFIC GETTERS ////////////////////////////

    function isAllowedToDepositIntoBBV(address asset) external view override returns (bool) {
        return _configByAsset[asset].depositIntoBBVAllowed;
    }

    function isAllowedToWithdrawFromBBV(address asset) external view override returns (bool) {
        return _configByAsset[asset].withdrawFromBBVAllowed;
    }

    function isAllowedToDepositIntoAllocator(address asset) external view override returns (bool) {
        return _configByAsset[asset].depositIntoAllocatorAllowed;
    }

    function isAllowedToWithdrawFromAllocator(address asset) external view override returns (bool) {
        return _configByAsset[asset].withdrawFromAllocatorAllowed;
    }

    function isAllowedSwapInputToken(address asset) external view override returns (bool) {
        return _configByAsset[asset].swapInputTokenAllowed;
    }

    function isAllowedSwapOutputToken(address asset) external view override returns (bool) {
        return _configByAsset[asset].swapOutputTokenAllowed;
    }
}
