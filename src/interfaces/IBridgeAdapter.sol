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

    /// @notice Emitted when a message is received before being processed.
    /// @dev The message id matches the one in the `MessagePublished` event.
    event MessageReceived(bytes32 indexed messageId);

    /// @notice Emitted when the destination chain adapter is set.
    event DestinationChainAdapterSet(uint256 indexed chainId, address indexed destinationChainAdapter);

    /// @notice Address checked is not the destination chain adapter.
    /// @custom:selector 0x75503511
    error OnlyDestinationChainAdapter();

    /// @notice Address checked is not the bridge router.
    /// @custom:selector 0x60055a30
    error OnlyBridgeRouter();

    /// @notice The parameters for the bridge adapter.
    /// @dev `feePayer` is intentionally NOT part of this struct. It is propagated as an explicit calldata
    /// parameter through every layer (entry → gateway → adapter), set to the entry-point's `msg.sender`.
    /// Putting it inside the opaque blob would make any non-zero ERC20 approval to the adapter consumable
    /// by ANY caller of ANY bridge entry-point — a forged blob `feePayer` would `safeTransferFrom` from the
    /// approval owner regardless of who triggered the bridge. Keeping `feePayer` outside the blob lets the
    /// trusted entry-point bind it to caller identity.
    /// @param feeToken Token to pay the bridge fee in.
    /// @param feeAmount Amount of `feeToken` approved by `feePayer` to spend on fees.
    /// @param feeRefundThreshold Minimum amount of `feeToken` that must remain unused in order to trigger a refund to
    /// the `feePayer`.
    /// @param gasLimit Total gas that should be allocated for executions that take place from the message being
    /// processed on the destination chain (including round trips).
    /// @param data Arbitrary data that may be required by the bridge adapter to operate.
    struct BridgeParams {
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

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain.
    /// @dev `bridgeParamsEncoded` is `BridgeParamsCodec.encode(BridgeParams)`. The adapter is the sole
    /// decoder — Gateway and intermediate layers forward the blob opaquely. The adapter also owns bridge-
    /// fee staging (pulls from `feePayer` via TransferHelper, spends on the underlying router, refunds
    /// excess per `feeRefundThreshold`).
    /// @dev `feePayer` is forwarded by the gateway as an explicit calldata parameter, not decoded from
    /// the blob — see `BridgeParams` NatSpec for rationale.
    /// @param destinationChainId Chain id of the chain to publish the message to.
    /// @param asset Asset to bridge; set to `address(0)` for data only messages.
    /// @param amount Amount of the asset to bridge; set to 0 for data only messages.
    /// @param data Arbitrary data that would be decoded and handled by the destination chain.
    /// @param feePayer Address that will pay the bridge fee (also the recipient of any refund). Set by the
    /// trusted entry-point to the original caller's `msg.sender`.
    /// @param bridgeParamsEncoded ABI-encoded `BridgeParams` blob; decoded inside the adapter.
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory data,
        address feePayer,
        bytes memory bridgeParamsEncoded
    ) external payable;
}
