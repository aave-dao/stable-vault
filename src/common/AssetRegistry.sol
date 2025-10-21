// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// TODO: This is a draft, but the final code might not differ much from this
// TODO: add events
// TODO: use timelocks on updates?
contract AssetRegistry is Ownable {
    event AssetConfigSet(address asset, uint256 config);

    uint8 constant BBV_DEPOSIT_BIT = 0;
    uint8 constant BBV_WITHDRAW_BIT = 1;
    uint8 constant ALLOCATOR_DEPOSIT_BIT = 2;
    uint8 constant ALLOCATOR_WITHDRAW_BIT = 3;

    // If we do not have more than 32 permissions, it might make sense to do a struct with booleans
    mapping(address asset => uint256 assetConfig) internal _configByAsset;

    struct AssetConfig {
        bool isAllowedToDepositIntoBBV; // uint8
        bool isAllowedToWithdrawFromBBV;
        bool isAllowedToDepositIntoAllocator;
        bool isAllowedToWithdrawFromAllocator;
        // ...up to 32 permissions (alternative storage approach for _configByAsset)
    }

    constructor(address owner) Ownable(owner) {}

    function setAssetConfigBitmap(address asset, uint256 config) external onlyOwner {
        // check asset has balanceOf function as interface verification method - maybe not needed as the admin calls it
        IERC20(asset).balanceOf(address(this));
        _configByAsset[asset] = config;
        emit AssetConfigSet(asset, config);
    }

    function getAssetConfigBitmap(address asset) external view returns (uint256) {
        return _configByAsset[asset];
    }

    ///////////////////////// PERMISSION SPECIFIC GETTERS ////////////////////////////

    function isAllowedToDepositIntoBBV(address asset) external view returns (bool) {
        return _isAllowedTo(asset, BBV_DEPOSIT_BIT);
    }

    function isAllowedToWithdrawFromBBV(address asset) external view returns (bool) {
        return _isAllowedTo(asset, BBV_WITHDRAW_BIT);
    }

    function isAllowedToDepositIntoAllocator(address asset) external view returns (bool) {
        return _isAllowedTo(asset, ALLOCATOR_DEPOSIT_BIT);
    }

    function isAllowedToWithdrawFromAllocator(address asset) external view returns (bool) {
        return _isAllowedTo(asset, ALLOCATOR_WITHDRAW_BIT);
    }

    //////////////////////////// INTERNAL HELPERS ////////////////////////////

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
