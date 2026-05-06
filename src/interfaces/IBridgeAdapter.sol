// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the base BridgeAdapter contract.
interface IBridgeAdapter {
    /// @notice Emitted when a message is published to the bridge provider.
    /// @dev The message id matches the one in the `MessageReceived` event.
    event MessagePublished(bytes32 indexed messageId);

    /// @notice Emitted when a message is received and processed.
    /// @dev The message id matches the one in the `MessagePublished` event.
    event MessageReceived(bytes32 indexed messageId);

    /// @notice Emitted when the destination chain adapter is set.
    event DestinationChainAdapterSet(uint256 indexed chainId, address indexed destinationChainAdapter);

    /// @notice Thrown when the number of tokens in a message is greater than the max expected.
    /// @custom:selector 0xe778681d
    error InvalidTokenCount();

    /// @notice Address checked is not the destination chain adapter.
    /// @custom:selector 0x75503511
    error OnlyDestinationChainAdapter();

    /// @notice Address checked is not the bridge router.
    /// @custom:selector 0x60055a30
    error OnlyBridgeRouter();

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

    /// @notice Sends a data-only message to a destination chain.
    /// @param destinationChainId Chain id of the chain to publish the message to.
    /// @param messageData Data decoded and handled by the destination gateway.
    /// @param feePayer Address that will pay the bridge fee.
    /// @param payloadExecutionGasLimit Gas limit for the destination gateway call and everything it executes.
    /// @param bridgeAdapterData Any bridge adapter custom parameters that it may need to operate.
    /// @dev The adapter should add its own gas overhead to `payloadExecutionGasLimit` when executing the message.
    function publishDataOnlyMessage(
        uint256 destinationChainId,
        bytes memory messageData,
        address feePayer,
        uint256 payloadExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) external payable;

    /// @notice Sends funds, optionally with message data, to a destination chain.
    /// @param destinationChainId Chain id of the chain to publish the message to.
    /// @param asset Asset to bridge.
    /// @param amount Amount of the asset to bridge.
    /// @param messageData Data decoded and handled by the destination gateway.
    /// @param feePayer Address that will pay the bridge fee.
    /// @param receiverExecutionGasLimit Gas limit for destination receiver execution. This includes adapter receive
    /// logic, token handling, and the gateway call, but excludes bridge provider infrastructure.
    /// @param bridgeAdapterData Any bridge adapter custom parameters that it may need to operate.
    function publishMessageWithFunds(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory messageData,
        address feePayer,
        uint256 receiverExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) external payable;
}
