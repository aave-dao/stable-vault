// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title IChainGateway
/// @author Aave Labs
/// @notice Interface for handling the communication between chains for bridging assets and data.
/// @dev Assumes bridged assets and bridged data can be handled independently of each other.
interface IChainGateway {
    /// @notice Thrown when an adapter is not found for a given asset and chain.
    /// @custom:selector 0xf7b1bf8e
    error AdapterNotFound();

    /// @notice Thrown when the message type for the arbitrary message data is not recognized.
    /// @custom:selector 0x5b60892f
    error InvalidMessageType();

    /// @notice Thrown when the caller is not the IOU token manager.
    /// @custom:selector 0x4084b1f2
    error OnlyIouTokenManager();

    event BridgeAdapterAdded(address asset, uint256 chainId, address adapter);
    event BridgeAdapterRemoved(address asset, uint256 chainId, address adapter);
    event DefaultBridgeAdapterSet(address asset, uint256 chainId, address adapter);

    enum MessageType {
        INVALID,
        BALANCE_SNAPSHOT,
        BRIDGE_IOU_TOKEN,
        BURN_IOU_TOKEN
    }

    /// @notice The representation of a cross-chain message.
    /// @param messageType Type of message used to determine how to decode the `data` field.
    /// @param data Arbitrary data that may be required by the message type.
    struct CrossChainMessage {
        MessageType messageType;
        bytes data;
    }

    /// @notice The representation of a balance snapshot from a source chain.
    /// @dev For message type `BALANCE_SNAPSHOT`.
    /// @param totalAssetsInRay Cumulative balance of all tokens with common denomination in RAY.
    /// @param nonce Nonce of the balance snapshot.
    struct BalanceSnapshot {
        uint256 totalAssetsInRay;
        uint256 nonce;
    }

    /// @notice The representation of a message to bridge IOU tokens to a destination chain.
    /// @dev For message type `BRIDGE_IOU_TOKEN`.
    /// @param recipient Address to send the IOU tokens to on the destination chain.
    /// @param amount Amount of IOU tokens to bridge.
    struct IouTokenBridgeMessage {
        address recipient;
        uint256 amount;
    }

    /// @notice The representation of a message to burn IOU tokens on a source chain.
    /// @dev For message type `BURN_IOU_TOKEN`.
    /// @param iouTokenAmountBurnedRay Amount of IOU tokens to burn.
    /// @param chainBalanceSnapshotNonce Nonce of the balance snapshot on the source chain.
    /// @param balanceSnapshotTotalAssetsInRay Cumulative balance of all tokens with common denomination in RAY on the
    /// source chain.
    struct BurnIouTokenMessage {
        uint256 iouTokenAmountBurnedRay;
        uint256 chainBalanceSnapshotNonce;
        uint256 balanceSnapshotTotalAssetsInRay;
    }

    /// @notice Gets the default bridge adapter for an asset and chain; the default adapter is used for outbound
    /// messages.
    /// @dev The adapter must be whitelisted for the asset and chain.
    /// @param asset The asset to get the default adapter for.
    /// @param chainId The chain id to get the default adapter for.
    /// @return The default adapter for the asset and chain.
    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view returns (address);

    /// @notice Adds a bridge adapter to the gateway's set of whitelisted adapters.
    /// @dev The adapter must not be already whitelisted for the asset and chain.
    /// @param asset The asset to add the adapter for.
    /// @param chainId The chain id to add the adapter for.
    /// @param adapter The adapter to add.
    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external;

    /// @notice Removes a bridge adapter from the gateway's set of whitelisted adapters.
    /// @dev If the adapter is the default adapter for the asset and chain, the default adapter is unset.
    /// @param asset The asset to remove the adapter for.
    /// @param chainId The chain id to remove the adapter for.
    /// @param adapter The adapter to remove.
    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external;

    /// @notice Sets the default bridge adapter for an asset and chain; the default adapter is used for outbound
    /// messages.
    /// @dev The adapter must be whitelisted for the asset and chain.
    /// @param asset The asset to set the default adapter for.
    /// @param chainId The chain id to set the default adapter for.
    /// @param adapter The adapter to set as the default.
    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external;

    /// @notice Handle receiving of a data and funds from a source chain.
    /// @param sourceChainId The chain from which the message was sent from.
    /// @param data The data that was sent from a source chain.
    /// @param assets The assets bridged over from a source chain.
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external;

    /// @notice Sends a message to bridge IOU tokens to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param iouTokenRecipient The address to send the IOU tokens to on the destination chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to bridge.
    /// @param bridgeParams The parameters for the bridge adapter.
    function sendBridgeIouTokenMessageWithFeePayer(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable;
}
