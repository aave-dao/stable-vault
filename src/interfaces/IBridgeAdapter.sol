// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBridgeAdapter {
    /// @notice Emitted when the processing of bridged funds fails.
    event BridgedFundsProcessingFailed(uint256 sourceChainId, bytes message, bytes error);

    /// @notice Address checked is not the destination chain adapter.
    /// @custom:selector 0x75503511
    error OnlyDestinationChainAdapter();

    /// @notice Address checked is not the bridge router.
    /// @custom:selector 0x60055a30
    error OnlyBridgeRouter();

    struct BridgeAsset {
        address asset;
        uint256 amount;
    }

    struct BridgeParams {
        // The address that will pay the bridge fee (also the recipient of any refund).
        address feePayer;
        // The token to pay the bridge fee in.
        address feeToken;
        // The amount of `feeToken` approved by `feePayer` to spend on fees.
        uint256 feeAmount;
        // The minimum amount of `feeToken` that must remain unused in order to trigger a refund to the `feePayer`.
        uint256 feeRefundThreshold;
        // Total gas that should be allocated for executions that take place from the message being processed on the
        // destination chain (including round trips).
        uint256 gasLimit;
        // Arbitrary data that may be required by the bridge adapter to operate.
        bytes data;
    }

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external;

    function replayFundsReceiving(BridgeAsset[] memory assets) external;

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param assets The assets to bridge.
    /// @param data The arbitrary data that would be decoded and handled by the destination chain.
    /// @param bridgeParams The parameters for the bridge adapter.
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data,
        BridgeParams memory bridgeParams
    ) external payable;
}
