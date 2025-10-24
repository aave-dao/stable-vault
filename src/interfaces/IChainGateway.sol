// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "./IBridgeAdapter.sol";

/// @notice Interface for handling the communication between chains for bridging assets and data.
/// @dev Assumes bridged assets and bridged data can be handled independently of each other.
interface IChainGateway {
    error InvalidMessageType();

    enum MessageType {
        BALANCE_SNAPSHOT,
        BRIDGE_IOUTOKEN,
        BURN_IOUTOKEN
    }

    struct CrossChainMessage {
        MessageType messageType;
        bytes data;
    }
    /// @notice Struct for arbitrary data containing a balance snapshot from a source chain.

    struct BalanceSnapshot {
        // Cumulative balance of all tokens with common denomination in RAY.
        uint256 totalAssetsInRay;
        uint256 nonce;
    }

    struct IouTokenBridgeMessage {
        address recipient;
        uint256 amount;
    }

    struct BurnIouTokenMessage {
        uint256 iouTokenAmountBurnedRay;
        uint256 chainBalanceSnapshotNonce;
        uint256 balanceSnapshotTotalAssetsInRay;
    }

    /// @notice Handle receiving of a data and funds from a source chain.
    /// @param sourceChainId The chain from which the message was sent from.
    /// @param data The data that was sent from a source chain.
    /// @param assets The assets bridged over from a source chain.
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external;

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain.
    /// @param feeRefundRecipient The address to send the remaining bridge fee to if any. The actual fee is taken from
    /// the msg.sender.
    /// @param feeToken Token to pay the bridge fee in (must be accepted by the Bridge provider).
    /// @param feeAmount The amount of fee to pay in the fee token (a refund is provided to the fee payer if necessary).
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param iouTokenRecipient The address to send the IOU tokens to on the destination chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to bridge.
    function sendBridgeIouTokenMessageWithFeePayer(
        address feeRefundRecipient,
        address feeToken,
        uint256 feeAmount,
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) external payable;
}
