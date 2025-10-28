// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MathLib} from "../../src/libraries/MathLib.sol";
import {IMockErc20} from "../mocks/MockErc20.sol";
import {Test} from "forge-std/Test.sol";

contract TestWithHelpers is Test {
    function _boundRate(uint256 rate) internal pure returns (uint256) {
        return bound(rate, MathLib.RAY, type(uint256).max);
    }

    function _boundRayAmountAllowingZero(uint256 amount) internal pure returns (uint256) {
        return _boundAmountAllowingZero(amount, MathLib.RAY);
    }

    function _boundAssetAmount(address asset, uint256 amount) internal view returns (uint256) {
        return _boundNonZeroAmount(amount, 10 ** IMockErc20(asset).decimals());
    }

    function _boundAssetAmountAllowingZero(address asset, uint256 amount) internal view returns (uint256) {
        return _boundAmountAllowingZero(amount, 10 ** IMockErc20(asset).decimals());
    }

    function _boundNativeAmount(uint256 amount) internal pure returns (uint256) {
        return _boundNonZeroAmount(amount, 10 ** 18);
    }

    function _boundNativeAmountAllowingZero(uint256 amount) internal pure returns (uint256) {
        return _boundAmountAllowingZero(amount, 10 ** 18);
    }

    function _boundRayAmount(uint256 amount) internal pure returns (uint256) {
        return _boundNonZeroAmount(amount, MathLib.RAY);
    }

    function _boundNonZeroAmount(uint256 amount, uint256 scaleFactor) internal pure returns (uint256) {
        return _boundAmount(amount, 1, scaleFactor);
    }

    function _boundAmountAllowingZero(uint256 amount, uint256 scaleFactor) internal pure returns (uint256) {
        return _boundAmount(amount, 0, scaleFactor);
    }

    function _boundAmount(uint256 amount, uint256 minAmount, uint256 scaleFactor) internal pure returns (uint256) {
        return bound(amount, minAmount, 100_000_000_000_000 * scaleFactor); // 100 trillion
    }
}
