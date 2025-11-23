// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ConstantsLib} from "../libraries/ConstantsLib.sol";

library AssetLib {
    error NonZeroRemainder();

    function assetDecimalsToRay(uint256 amount, address asset) internal view returns (uint256) {
        return convertDecimals(amount, getDecimals(asset), ConstantsLib.RAY_DECIMALS);
    }

    function rayToAssetDecimals(uint256 amount, address asset) internal view returns (uint256) {
        return convertDecimals(amount, ConstantsLib.RAY_DECIMALS, getDecimals(asset));
    }

    function convertAssetDecimals(uint256 amount, address fromAsset, address toAsset) internal view returns (uint256) {
        return convertDecimals(amount, getDecimals(fromAsset), getDecimals(toAsset));
    }

    /// @notice Converts `amount` from `fromAsset` to `toAsset` and reverts if there is a non zero remainder.
    /// @dev Used to avoid the system leaking the remainder of the `amount`.
    function safeConvertAssetDecimals(uint256 amount, address fromAsset, address toAsset)
        internal
        view
        returns (uint256)
    {
        uint8 inputDecimals = getDecimals(fromAsset);
        uint8 outputDecimals = getDecimals(toAsset);
        if (inputDecimals > outputDecimals && amount % 10 ** (inputDecimals - outputDecimals) != 0) {
            revert NonZeroRemainder();
        }
        return convertDecimals(amount, inputDecimals, outputDecimals);
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
                // Casting to uint8 is safe because we are checking the value is not greater than type(uint8).max
                // forge-lint: disable-next-line(unsafe-typecast)
                assetDecimals = uint8(returnedDecimals);
            }
        }
        return assetDecimals;
    }
}
