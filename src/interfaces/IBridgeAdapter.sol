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

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain.
    /// @param feeRefundRecipient The address to send the remaining bridge fee to if any. The actual fee is taken from
    /// the msg.sender.
    /// @param feeToken Token to pay the bridge fee in (must be accepted by the Bridge provider).
    /// @param feeAmount The amount approved by msg.sender to use for fees (a refund is provided to the refundRecipient
    /// if necessary).
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param data The arbitrary data that would be decoded and handled by the destination chain.
    function publishMessageToChainWithFeePayer(
        address feeRefundRecipient,
        address feeToken,
        uint256 feeAmount,
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data
    ) external payable;
}
