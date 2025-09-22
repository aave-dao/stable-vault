// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

library MathLib {
    uint256 constant RAY = 1e27;

    function mulByRay(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return (a * b + RAY / 2) / RAY; // bankers' rounding
        }
    }

    function wadDivByRay(uint256 wadAmount, uint256 rayDivisor) internal pure returns (uint256) {
        require(rayDivisor != 0, "DIV_BY_ZERO");
        unchecked {
            return (wadAmount * RAY + rayDivisor / 2) / rayDivisor;
        }
    }

    function rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := RAY }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := RAY }
                default { z := x }
                let half := div(RAY, 2)
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, RAY)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }
}
