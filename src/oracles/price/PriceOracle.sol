// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {MathLib} from "src/libraries/MathLib.sol";

/// @title PriceOracle
/// @author Aave Labs
/// @notice Oracle contract for fetching asset prices through an adapter to an underlying data source.
/// @dev Assumes all configured assets have the same denomination.
/// @custom:upgradeable
contract PriceOracle is AccessManagedUpgradeable, IPriceOracle {
    uint256 immutable MIN_VALID_PRICE_RAY;

    uint256 constant MAX_PRICE_RAY = MathLib.RAY;

    /// @custom:storage-location erc7201:aave.storage.PriceOracle
    struct PriceOracleStorage {
        /// @dev Set of asset specific adapters for asset price oracles.
        mapping(address asset => address oracleAdapter) oracleAdapterByAsset;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.PriceOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_PRICE_ORACLE =
        0xe000f1dda5abe64dd1a0f674dea4aff2aee707620120c15bf2636fc080c92900;

    function $storage() private pure returns (PriceOracleStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_PRICE_ORACLE
        }
    }

    /// @dev Constructor.
    /// @param minValidPriceRay The minimum valid price in ray units (27 decimals).
    constructor(uint256 minValidPriceRay) {
        require(minValidPriceRay <= MathLib.RAY && minValidPriceRay > 0, InvalidMinPrice());
        _disableInitializers();
        MIN_VALID_PRICE_RAY = minValidPriceRay;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __PriceOracle_init(accessManager);
    }

    function __PriceOracle_init(address accessManager) internal virtual onlyInitializing {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        __AccessManaged_init(accessManager);
    }

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view override returns (uint256) {
        return _getPrice(asset);
    }

    /// @inheritdoc IPriceOracle
    function getPrices(address[] calldata assets) external view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = _getPrice(assets[i]);
        }
        return prices;
    }

    /// @inheritdoc IPriceOracle
    function validatePrice(address asset) external view override {
        address oracleAdapter = $storage().oracleAdapterByAsset[asset];
        require(oracleAdapter != address(0), OracleAdapterNotFound(asset));
        IPriceOracleAdapter.OracleResponse memory response = IPriceOracleAdapter(oracleAdapter).getPrice(asset);
        require(!response.isStale, IPriceOracle.StalePrice());
        require(response.priceRay >= MIN_VALID_PRICE_RAY, IPriceOracle.PriceTooLow());
    }

    function getOracleAdapterForAsset(address asset) external view returns (address) {
        return $storage().oracleAdapterByAsset[asset];
    }

    function setOracleAdapterForAsset(address asset, address newAdapter) external restricted {
        // Validate the adapter interface through a call to getPrice
        IPriceOracleAdapter(newAdapter).getPrice(asset);
        address previousAdapter = $storage().oracleAdapterByAsset[asset];
        $storage().oracleAdapterByAsset[asset] = newAdapter;
        emit OracleAdapterSet(asset, newAdapter, previousAdapter);
    }

    function _getPrice(address asset) internal view returns (uint256 price) {
        address oracleAdapter = $storage().oracleAdapterByAsset[asset];
        require(oracleAdapter != address(0), OracleAdapterNotFound(asset));
        IPriceOracleAdapter.OracleResponse memory response = IPriceOracleAdapter(oracleAdapter).getPrice(asset);
        return response.isStale ? 0 : _capToMaxPrice(response.priceRay);
    }

    function _capToMaxPrice(uint256 priceRay) internal pure returns (uint256) {
        return priceRay > MAX_PRICE_RAY ? MAX_PRICE_RAY : priceRay;
    }
}
