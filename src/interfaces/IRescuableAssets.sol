// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IRescuableAssets {
    /// @dev Rescue tokens stuck on the contract.
    /// @param asset The asset to rescue.
    /// @param amount The amount of the asset to rescue.
    function rescueTokens(address asset, uint256 amount) external;
}
