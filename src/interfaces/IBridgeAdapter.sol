// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the base BridgeAdapter contract.
interface IBridgeAdapter {
    /// @notice Emitted when the processing of bridged funds fails.
    event BridgedFundsProcessingFailed(uint256 sourceChainId, bytes message, bytes error);

    /// @notice Emitted when a message is published with a given message id from the bridge provider.
    /// @dev The message id matches the one in the `MessageReceived` event.
    event MessagePublished(bytes32 indexed messageId);

    /// @notice Emitted when a message is received with a given message id from the bridge provider.
    /// @dev The message id matches the one in the `MessagePublished` event.
    event MessageReceived(bytes32 indexed messageId);

    /// @notice Emitted when the processing of a received token fails downstream from the adapter.
    /// @dev Indicates that the token will remain on the adapter contract.
    event TokenReceptionFailed(uint256 indexed sourceChainId, address indexed asset, uint256 amount);

    /// @notice Thrown when arbitrary data is not allowed to be bridged.
    /// @custom:selector 0x48c51a0f
    error ArbitraryDataNotAllowed();

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

    /// @notice The parameters for the bridge adapter.
    /// @param feePayer Address that will pay the bridge fee (also the recipient of any refund).
    /// @param feeToken Token to pay the bridge fee in.
    /// @param feeAmount Amount of `feeToken` approved by `feePayer` to spend on fees.
    /// @param feeRefundThreshold Minimum amount of `feeToken` that must remain unused in order to trigger a refund to
    /// the `feePayer`.
    /// @param gasLimit Total gas that should be allocated for executions that take place from the message being
    /// processed on the destination chain (including round trips).
    /// @param data Arbitrary data that may be required by the bridge adapter to operate.
    struct BridgeParams {
        address feePayer;
        address feeToken;
        uint256 feeAmount;
        uint256 feeRefundThreshold;
        uint256 gasLimit;
        bytes data;
    }

    /// @notice Getter for the address of the Gateway contract.
    /// @return gateway Address of the Gateway contract.
    function getGateway() external view returns (address);

    /// @notice Sets the destination chain adapter for a given chain id.
    /// @dev The adapter on the destination chain must support receiving of messages from the bridge which this adapter
    /// publishes to.
    /// @dev This destination adapter is used to receive funds and arbitrary data on the destination chain.
    /// @param chainId Chain id of the chain to set the destination adapter for.
    /// @param destinationChainAdapter Address of the destination chain adapter.
    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external;

    /// @notice Replays the funds receiving process for a given source chain and assets. Assets must be on this
    /// contract.
    /// @param assets Assets to replay the receiving process for.
    function replayFundsReceiving(BridgeAsset[] memory assets) external;

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain.
    /// @param destinationChainId Chain id of the chain to publish the message to.
    /// @param assets Assets to bridge.
    /// @param data Arbitrary data that would be decoded and handled by the destination chain.
    /// @param bridgeParams Parameters for the bridge adapter.
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data,
        BridgeParams memory bridgeParams
    ) external payable;
}
