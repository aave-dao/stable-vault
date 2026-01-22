// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {Errors} from "src/types/Errors.sol";

// TODO: make this upgradeable, and AccessManaged
contract PriceOracle is IPriceOracle {
    // TODO: Instead of storing target + max deviation, just store the min valid price in ray
    // (1 * (100_00 - MAX_DEVIATION_BPS)) / 100_00;
    uint256 immutable MIN_VALID_PRICE_RAY;

    mapping(address asset => address oracleAdapter) internal _oracleAdapterByAsset;

    constructor(uint256 minValidPriceRay) {
        MIN_VALID_PRICE_RAY = minValidPriceRay;
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
            IPriceOracleAdapter(_oracleAdapterByAsset[asset]).getPrice(asset);
        require(!response.isStale, Errors.StalePrice());
        require(response.priceRay >= MIN_VALID_PRICE_RAY, Errors.InvalidPrice());
    }

    function setOracleAdapterForAsset(address asset, address adapter) external /* restricted */  {
        // Validate the adapter interface through a call to getPrice
        IPriceOracleAdapter(adapter).getPrice(asset);
        _oracleAdapterByAsset[asset] = adapter;
    }

    function _getPrice(address asset) internal view returns (uint256 price) {
        // TODO: what to do if we don't have an oracle adapter for an asset?
        IPriceOracleAdapter.OracleResponse memory response =
            IPriceOracleAdapter(_oracleAdapterByAsset[asset]).getPrice(asset);
        if (response.isStale) {
            return 0;
        } else {
            return response.priceRay;
        }
    }
}
