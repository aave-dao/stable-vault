// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

contract AssetRegistry is AccessManagedUpgradeable, IAssetRegistry {
    /// @custom:storage-location erc7201:aave.storage.AssetRegistry
    struct AssetRegistryStorage {
        mapping(address asset => AssetConfig config) configByAsset;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.AssetRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_ASSET_REGISTRY =
        0xe40dab217194b6f9bf5c5919f11bf88986c74d7e324e41f214286ca4657cc900;

    function $storage() private pure returns (AssetRegistryStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_ASSET_REGISTRY
        }
    }

    function $AssetRegistry() internal pure returns (AssetRegistryStorage storage) {
        return $storage();
    }

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
        $storage().configByAsset[asset] = config;
        emit AssetConfigSet(asset, config);
    }

    // /////////////////////// PERMISSION SPECIFIC GETTERS ////////////////////////////

    function isAllowedToDepositIntoBBV(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].depositIntoBBVAllowed;
    }

    function isAllowedToWithdrawFromBBV(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].withdrawFromBBVAllowed;
    }

    function isAllowedToDepositIntoAllocator(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].depositIntoAllocatorAllowed;
    }

    function isAllowedToWithdrawFromAllocator(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].withdrawFromAllocatorAllowed;
    }

    function isAllowedSwapInputToken(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].swapInputTokenAllowed;
    }

    function isAllowedSwapOutputToken(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].swapOutputTokenAllowed;
    }
}
