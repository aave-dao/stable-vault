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

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external;

    function replayFundsReceiving(uint256 sourceChainId, BridgeAsset[] memory assets) external;

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param assets The assets to bridge.
    /// @param data The arbitrary data that would be decoded and handled by the destination chain.
    /// @param feePayer The address paying the bridge fee and which receives a refund if any.
    /// @param feeToken Token to pay the bridge fee in (must be accepted by the Bridge provider).
    /// @param allocatedFeeAmount The amount approved by feePayer to use for fees.
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data,
        address feePayer,
        address feeToken,
        uint256 allocatedFeeAmount
    ) external payable;
}
