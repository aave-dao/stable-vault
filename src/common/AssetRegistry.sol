// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

contract AssetRegistry is AccessManagedUpgradeable, IAssetRegistry {
    mapping(address asset => AssetConfig config) internal _configByAsset;

    /// @dev Constructor. Just disables initializers.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __AssetRegistry_init(accessManager);
    }

    function __AssetRegistry_init(address accessManager) internal virtual onlyInitializing {
        __AccessManaged_init(accessManager);
    }

    function setAssetConfig(address asset, AssetConfig memory config) external restricted {
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
