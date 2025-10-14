// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBridgeCommunicationHandler {
    /// @notice Pushes a specific asset to be allocated to a strategy.
    /// @param sourceChainId The chain from which funds were sent to be allocated to a strategy.
    /// @param asset The asset to push to a strategy.
    /// @param amount The `amount` must be in the given `asset` token decimal places.
    function receiveFunds(uint256 sourceChainId, address asset, uint256 amount) external;
}
