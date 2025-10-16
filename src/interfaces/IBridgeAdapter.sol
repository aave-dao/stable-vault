// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBridgeAdapter {
    struct BridgeAsset {
        address asset;
        uint256 amount;
    }

    /// @notice Sends tokens and/or an arbitrary message containing instructions or data updates to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param assets The assets to push to the destination chain.
    /// @param data The arbitrary data that would be decoded and handled by the destination chain.
    function publishMessageToChain(uint256 destinationChainId, BridgeAsset[] memory assets, bytes memory data) external;
}
