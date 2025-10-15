// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// TODO: This is for the accounting side only...?
interface IBridgeAdapter {
    struct BridgeAsset {
        address asset;
        uint256 amount;
    }

    /// @notice Bridges assets and an optional message to a destination chain.
    /// @param destinationChainId The chain id of the chain to push funds to.
    /// @param assets The assets to push to the destination chain.
    function pushFundsToChain(uint256 destinationChainId, BridgeAsset[] memory assets) external;

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param message The arbitrary message that would be decoded and handled by the destination chain.
    function publishMessageToChain(uint256 destinationChainId, bytes memory message) external;
}
