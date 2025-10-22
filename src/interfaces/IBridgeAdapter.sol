// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBridgeAdapter {
    /// @notice Emitted when the processing of bridged funds fails.
    event BridgedFundsProcessingFailed(uint256 sourceChainId, bytes message, bytes error);

    error NotBridgeRouter();

    struct BridgeAsset {
        address asset;
        uint256 amount;
    }

    /// @notice Sends tokens and/or an arbitrary message containing instructions or data updates to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param assets The assets to push to the destination chain.
    /// @param data The arbitrary data that would be decoded and handled by the destination chain.
    function publishMessageToChain(uint256 destinationChainId, BridgeAsset[] memory assets, bytes memory data) external;

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain with a fee
    /// payer and fee token.
    /// @param feePayer Account which funds will be pulled from to pay the bridge fee (this address
    /// must approve the BridgeAdapter to spend the fee token).
    /// @param feeToken Token to pay the bridge fee in (must be accepted by the Bridge provider).
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param data The arbitrary data that would be decoded and handled by the destination chain.
    function publishMessageToChainWithFeePayer(
        address feePayer,
        address feeToken,
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data
    ) external;
}
