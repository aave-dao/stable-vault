// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ConstantsLib} from "src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";
import {Multicall} from "src/misc/Multicall.sol";

/// @title AssetRegistry
/// @author Aave Labs
/// @notice AssetRegistry contract for managing asset configurations.
/// @dev Inherits from Multicall to allow disabling deposits for multiple assets in a single call.
contract AssetRegistry is AccessManagedUpgradeable, Multicall, IAssetRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:aave.storage.AssetRegistry
    struct AssetRegistryStorage {
        mapping(address asset => AssetConfig config) configByAsset;
        EnumerableSet.AddressSet assets;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.AssetRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_ASSET_REGISTRY =
        0xe40dab217194b6f9bf5c5919f11bf88986c74d7e324e41f214286ca4657cc900;

    function $storage() private pure returns (AssetRegistryStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_ASSET_REGISTRY
        }
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

    /// @inheritdoc IAssetRegistry
    function setAssetConfig(address asset, AssetConfig memory config) external override restricted {
        // The system uses RAY Math (27 decimals), so we leave a 9-decimal place (27 - 18) margin for better precision.
        require(
            IERC20Metadata(asset).decimals() <= ConstantsLib.MAX_SUPPORTED_ASSET_DECIMALS, ErrorsLib.InvalidAsset(asset)
        );
        $storage().configByAsset[asset] = config;
        $storage().assets.add(asset);
        emit AssetConfigSet(asset, config);
    }

    /// @inheritdoc IAssetRegistry
    function disableDeposits(address asset, bool disableUserDeposits, bool disableAllocatorDeposits)
        external
        override
        restricted
    {
        bool isUserDepositsAllowed = $storage().configByAsset[asset].depositFromUserAllowed;
        if (isUserDepositsAllowed && disableUserDeposits) {
            $storage().configByAsset[asset].depositFromUserAllowed = false;
        }
        bool isAllocatorDepositsAllowed = $storage().configByAsset[asset].depositIntoAllocatorAllowed;
        if (isAllocatorDepositsAllowed && disableAllocatorDeposits) {
            $storage().configByAsset[asset].depositIntoAllocatorAllowed = false;
        }
    }

    // /////////////////////// PERMISSION SPECIFIC GETTERS ////////////////////////////

    /// @inheritdoc IAssetRegistry
    function isUserDepositAllowed(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].depositFromUserAllowed;
    }

    /// @inheritdoc IAssetRegistry
    function isUserWithdrawalAllowed(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].withdrawToUserAllowed;
    }

    /// @inheritdoc IAssetRegistry
    function isDepositToAllocatorAllowed(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].depositIntoAllocatorAllowed;
    }

    /// @inheritdoc IAssetRegistry
    function isWithdrawalFromAllocatorAllowed(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].withdrawFromAllocatorAllowed;
    }

    /// @inheritdoc IAssetRegistry
    function isSwapInputAllowed(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].swapInputTokenAllowed;
    }

    /// @inheritdoc IAssetRegistry
    function isSwapOutputAllowed(address asset) external view override returns (bool) {
        return $storage().configByAsset[asset].swapOutputTokenAllowed;
    }

    /// @inheritdoc IAssetRegistry
    function getRegisteredAssets() external view override returns (address[] memory) {
        return $storage().assets.values();
    }
}
