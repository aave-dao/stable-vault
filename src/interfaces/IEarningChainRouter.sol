// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IEarningChainRouter {
    /// @notice Sends a balance update to the Accounting Chain.
    function sendBalanceUpdate() external;

    /// @notice Withdraws a specific asset from the Allocator and bridges it to the Accounting Chain.
    /// @param amount The `amount` must be in RAY to be token agnostic.
    function exit(address asset, uint256 amount) external;

    /// @notice Withdraws any combination of assets from the Allocator and bridges them to the Accounting Chain.
    /// @param amount The `amount` must be in RAY to be token agnostic.
    function emergencyExit(uint256 amount) external;
}
