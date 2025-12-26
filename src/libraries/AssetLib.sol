// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Constants} from "src/types/Constants.sol";

/// @title AssetLib
/// @author Aave Labs
/// @notice Library for converting between asset decimals and ray.
library AssetLib {
    /// @notice Thrown when failing to get asset decimals.
    /// @custom:selector 0x294bbc84
    error CannotGetAssetDecimals(address asset);

    function assetDecimalsToRay(uint256 amount, address asset) internal view returns (uint256) {
        return convertDecimals(amount, getDecimals(asset), Constants.RAY_DECIMALS);
    }

    function rayToAssetDecimals(uint256 amount, address asset) internal view returns (uint256) {
        return convertDecimals(amount, Constants.RAY_DECIMALS, getDecimals(asset));
    }

    function convertAssetDecimals(uint256 amount, address fromAsset, address toAsset) internal view returns (uint256) {
        return convertDecimals(amount, getDecimals(fromAsset), getDecimals(toAsset));
    }

    function convertDecimals(uint256 inputAmount, uint256 inputDecimals, uint256 outputDecimals)
        internal
        pure
        returns (uint256)
    {
        if (inputDecimals == outputDecimals) {
            return inputAmount;
        } else if (inputDecimals < outputDecimals) {
            uint256 multiplier = 10 ** (outputDecimals - inputDecimals);
            return inputAmount * multiplier;
        } else {
            uint256 divisor = 10 ** (inputDecimals - outputDecimals);
            // Intentionally truncating instead of rounding
            return inputAmount / divisor;
        }
    }

    function getDecimals(address asset) internal view returns (uint8) {
        (bool callSucceeded, bytes memory encodedDecimals) =
            address(asset).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (callSucceeded && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                // Casting to uint8 is safe because we are checking the value is not greater than type(uint8).max
                // forge-lint: disable-next-line(unsafe-typecast)
                return uint8(returnedDecimals);
            }
        }
        revert CannotGetAssetDecimals(asset);
    }
}
