// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {Errors} from "src/types/Errors.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 internal _minValidPriceRay;
    mapping(address asset => uint256 price) internal _prices;

    function mockMinValidPrice(uint256 minValidPriceRay) external {
        _minValidPriceRay = minValidPriceRay;
    }

    function mockPrice(address asset, uint256 priceRay) external {
        _prices[asset] = priceRay;
    }

    function getPrice(address asset) external view override returns (uint256) {
        return _prices[asset];
    }

    function getPrices(address[] calldata assets) external view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = _prices[assets[i]];
        }
        return prices;
    }

    function validatePrice(address asset) external view override {
        if (_prices[asset] < _minValidPriceRay) {
            revert Errors.InvalidPrice();
        }
    }
}
