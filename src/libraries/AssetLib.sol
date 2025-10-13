// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library AssetLib {
    uint256 constant RAY_DECIMALS = 27;

    function assetDecimalsToRay(uint256 amount, address asset) internal view returns (uint256) {
        return convertDecimals(amount, getDecimals(asset), RAY_DECIMALS);
    }

    function rayToAssetDecimals(uint256 amount, address asset) internal view returns (uint256) {
        return convertDecimals(amount, RAY_DECIMALS, getDecimals(asset));
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
        uint8 assetDecimals = 18;
        (bool callSucceeded, bytes memory encodedDecimals) =
            address(asset).staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (callSucceeded && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                assetDecimals = uint8(returnedDecimals);
            }
        }
        return assetDecimals;
    }
}
