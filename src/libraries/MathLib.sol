// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";

/// @title MathLib
/// @author Aave Labs
/// @notice Util library for math operations.
library MathLib {
    uint256 constant RAY = 1e27;

    /// @dev Multiplies two ray, rounding down
    /// @dev assembly optimized for improved gas savings, see
    /// https://twitter.com/transmissions11/status/1451131036377571328
    /// @param a Ray
    /// @param b Ray
    /// @return c = floor(a*b), in ray
    function rayMulDown(uint256 a, uint256 b) internal pure returns (uint256 c) {
        // to avoid overflow, a <= type(uint256).max / b
        assembly ("memory-safe") {
            if iszero(or(iszero(b), iszero(gt(a, div(not(0), b))))) { revert(0, 0) }

            c := div(mul(a, b), RAY)
        }
    }

    /// @dev Multiplies two ray, rounding up
    /// @dev assembly optimized for improved gas savings, see
    /// https://twitter.com/transmissions11/status/1451131036377571328
    /// @param a Ray
    /// @param b Ray
    /// @return c = ceil(a*b), in ray
    function rayMulUp(uint256 a, uint256 b) internal pure returns (uint256 c) {
        // to avoid overflow, a <= type(uint256).max / b
        assembly ("memory-safe") {
            if iszero(or(iszero(b), iszero(gt(a, div(not(0), b))))) { revert(0, 0) }
            c := mul(a, b)
            // Add 1 if (a * b) % RAY > 0 to round up the division of (a * b) by RAY
            c := add(div(c, RAY), gt(mod(c, RAY), 0))
        }
    }

    /// @dev Divides two ray, rounding down
    /// @dev assembly optimized for improved gas savings, see
    /// https://twitter.com/transmissions11/status/1451131036377571328
    /// @param a Ray
    /// @param b Ray
    /// @return c = floor(a/b), in ray
    function rayDivDown(uint256 a, uint256 b) internal pure returns (uint256 c) {
        // to avoid overflow, a <= type(uint256).max / RAY
        assembly ("memory-safe") {
            if or(iszero(b), iszero(iszero(gt(a, div(not(0), RAY))))) { revert(0, 0) }

            c := div(mul(a, RAY), b)
        }
    }

    /// @notice Divides two Ray numbers, rounding up.
    /// @dev Reverts if division by zero or intermediate multiplication overflows.
    /// @return c = ceil(a * RAY / b) in Ray units.
    function rayDivUp(uint256 a, uint256 b) internal pure returns (uint256 c) {
        // to avoid overflow, a <= type(uint256).max / RAY
        assembly ("memory-safe") {
            if or(iszero(b), iszero(iszero(gt(a, div(not(0), RAY))))) { revert(0, 0) }
            c := mul(a, RAY)
            // Add 1 if (a * RAY) % b > 0 to round up the division of (a * RAY) by b
            c := add(div(c, b), gt(mod(c, b), 0))
        }
    }

    /// @notice Exponentiates `x` to `y` by squaring.
    /// @param x The base (in RAY)
    /// @param n The exponent (integer)
    /// @return The result, x^n (in RAY)
    function rpow(uint256 x, uint256 n) internal pure returns (uint256) {
        return FixedPointMathLib.rpow(x, n, RAY);
    }
}
