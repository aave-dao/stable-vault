// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.0;

import {AssetLib} from "src/libraries/AssetLib.sol";

contract AssetLibWrapper {
    function assetDecimalsToRay(uint256 amount, address asset) external view returns (uint256) {
        return AssetLib.assetDecimalsToRay(amount, asset);
    }

    function rayToAssetDecimals(uint256 amount, address asset) external view returns (uint256) {
        return AssetLib.rayToAssetDecimals(amount, asset);
    }

    function convertAssetDecimals(uint256 amount, address fromAsset, address toAsset) external view returns (uint256) {
        return AssetLib.convertAssetDecimals(amount, fromAsset, toAsset);
    }

    function convertDecimals(uint256 inputAmount, uint256 inputDecimals, uint256 outputDecimals)
        external
        pure
        returns (uint256)
    {
        return AssetLib.convertDecimals(inputAmount, inputDecimals, outputDecimals);
    }

    function getDecimals(address asset) external view returns (uint8) {
        return AssetLib.getDecimals(asset);
    }
}
