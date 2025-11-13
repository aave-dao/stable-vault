// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MathLib} from "src/libraries/MathLib.sol";

contract MathLibWrapper {
    uint256 public constant MAX_VSR = 1.000000021979553151239153027e27;

    function RAY() public pure returns (uint256) {
        return MathLib.RAY;
    }

    function rayMulDown(uint256 a, uint256 b) public pure returns (uint256) {
        return MathLib.rayMulDown(a, b);
    }

    function rayMulUp(uint256 a, uint256 b) public pure returns (uint256) {
        return MathLib.rayMulUp(a, b);
    }

    function rayDivDown(uint256 a, uint256 b) public pure returns (uint256) {
        return MathLib.rayDivDown(a, b);
    }

    function rayDivUp(uint256 a, uint256 b) public pure returns (uint256) {
        return MathLib.rayDivUp(a, b);
    }

    function rpow(uint256 x, uint256 n) public pure returns (uint256) {
        return MathLib.rpow(x, n);
    }
}
