// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

// TODO: This is a draft, but the final code might not differ much from this
// TODO: use timelocks on updates?
contract AssetRegistry is Ownable, IAssetRegistry {
    // Token is able to be deposited into BBV
    uint8 public constant BBV_DEPOSIT_BIT = 0;
    // Token is able to be withdrawn from BBV
    uint8 public constant BBV_WITHDRAW_BIT = 1;
    // Token is able to sit idle in an Allocator or in a strategy vault
    uint8 public constant ALLOCATOR_DEPOSIT_BIT = 2;
    // Token is able to be withdrawn from an Allocator or a strategy vault
    uint8 public constant ALLOCATOR_WITHDRAW_BIT = 3;
    // Token is able to be used as swap input token in the Allocator
    uint8 public constant ALLOCATOR_SWAP_IN_BIT = 4;
    // Token is able to be used as swap output token in the Allocator
    uint8 public constant ALLOCATOR_SWAP_OUT_BIT = 5;

    // If we do not have more than 32 permissions, it might make sense to do a struct with booleans
    mapping(address asset => uint256 assetConfig) internal _configByAsset;

    constructor(address owner) Ownable(owner) {}

    function registerAssetPermissions(address asset, uint8[] memory permissions) external onlyOwner {
        uint256 config = 0;
        for (uint256 i = 0; i < permissions.length; i++) {
            config |= _getMaskFor(permissions[i]);
        }
        this.setAssetConfigBitmap(asset, config);
    }

    function setAssetConfigBitmap(address asset, uint256 config) external onlyOwner {
        // check asset has balanceOf function as interface verification method - maybe not needed as the admin calls it
        IERC20(asset).balanceOf(address(this));
        _configByAsset[asset] = config;
        emit AssetConfigSet(asset, config);
    }

    function unregisterAsset(address asset) external onlyOwner {
        delete _configByAsset[asset];
        emit AssetConfigSet(asset, 0);
    }

    function getAssetConfigBitmap(address asset) external view returns (uint256) {
        return _configByAsset[asset];
    }

    // /////////////////////// PERMISSION SPECIFIC GETTERS ////////////////////////////

    function isAllowedToDepositIntoBBV(address asset) external view override returns (bool) {
        return _isAllowedTo(asset, BBV_DEPOSIT_BIT);
    }

    function isAllowedToWithdrawFromBBV(address asset) external view override returns (bool) {
        return _isAllowedTo(asset, BBV_WITHDRAW_BIT);
    }

    function isAllowedToDepositIntoAllocator(address asset) external view override returns (bool) {
        return _isAllowedTo(asset, ALLOCATOR_DEPOSIT_BIT);
    }

    function isAllowedToWithdrawFromAllocator(address asset) external view override returns (bool) {
        return _isAllowedTo(asset, ALLOCATOR_WITHDRAW_BIT);
    }

    function isAllowedSwapInputToken(address asset) external view override returns (bool) {
        return _isAllowedTo(asset, ALLOCATOR_SWAP_IN_BIT);
    }

    function isAllowedSwapOutputToken(address asset) external view override returns (bool) {
        return _isAllowedTo(asset, ALLOCATOR_SWAP_OUT_BIT);
    }

    // ////////////////////////// INTERNAL HELPERS ////////////////////////////

    function _getMaskFor(uint8 bit) internal pure returns (uint256) {
        uint256 zeroBitMask = 1; // Avoid "incorrect-shift" warning
        return zeroBitMask << bit;
    }

    function _isAllowedTo(address asset, uint8 bit) internal view returns (bool) {
        return _isAllowedTo(_configByAsset[asset], bit);
    }

    function _isAllowedTo(uint256 config, uint8 bit) internal pure returns (bool) {
        return (config & _getMaskFor(bit)) != 0;
    }
}
