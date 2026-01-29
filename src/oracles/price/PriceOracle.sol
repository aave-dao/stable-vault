// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Errors} from "src/types/Errors.sol";

contract PriceOracle is AccessManagedUpgradeable, IPriceOracle {
    // TODO: Instead of storing target + max deviation, just store the min valid price in ray
    // (1 * (100_00 - MAX_DEVIATION_BPS)) / 100_00;
    uint256 immutable MIN_VALID_PRICE_RAY;

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

    constructor(uint256 minValidPriceRay) {
        require(minValidPriceRay <= MathLib.RAY, InvalidMinPrice());
        _disableInitializers();
        MIN_VALID_PRICE_RAY = minValidPriceRay;
    }

    function __PriceOracle_init(address accessManager) internal virtual onlyInitializing {
        __AccessManaged_init(accessManager);
    }

    // TODO: How to handle stale prices?
    // Alternative #1: Return 0 if the price is stale
    // Alternative #2: Return (bubble-up) if stale or not, let the upper layer decide what to do with that
    function getPrice(address asset) external view override returns (uint256 price) {
        return _getPrice(asset);
    }

    function getPrices(address[] calldata assets) external view override returns (uint256[] memory prices) {
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = _getPrice(assets[i]);
        }
        return prices;
    }

    function validatePrice(address asset) external view override {
        IPriceOracleAdapter.OracleResponse memory response =
            IPriceOracleAdapter($storage().oracleAdapterByAsset[asset]).getPrice(asset);
        require(!response.isStale, Errors.StalePrice());
        require(response.priceRay >= MIN_VALID_PRICE_RAY, Errors.InvalidPrice());
    }

    function setOracleAdapterForAsset(address asset, address adapter) external restricted {
        IPriceOracleAdapter(adapter).getPrice(asset);
        address currentAdapter = $storage().oracleAdapterByAsset[asset];
        // Validate the adapter interface through a call to getPrice
        $storage().oracleAdapterByAsset[asset] = adapter;
        // TODO: emit ChainBalanceAdapterSet(currentAdapter, adapter);
    }

    function _getPrice(address asset) internal view returns (uint256 price) {
        address oracleAdapter = $storage().oracleAdapterByAsset[asset];
        if (oracleAdapter == address(0)) {
            // If no adapter is configured for the asset, be conservative and return 0.
            return 0;
        }
        IPriceOracleAdapter.OracleResponse memory response = IPriceOracleAdapter(oracleAdapter).getPrice(asset);
        return response.isStale ? 0 : response.priceRay;
    }
}
