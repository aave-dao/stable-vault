// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "./IBridgeAdapter.sol";

/// @notice Interface for handling the communication between chains for bridging assets and messages.
/// @dev Assumes bridged assets and bridged messages can be handled independently of each other.
interface IBridgeCommunicationHandler {
    /// @notice Struct for arbitrary messages containing a balance snapshot from a source chain.
    struct BalanceSnapshot {
        // Cumulative balance of all tokens with common denomination in RAY.
        uint256 balance;
        uint256 timestamp;
    }

    /// @notice Handle receiving of funds from a source chain.
    /// @param sourceChainId The chain from which funds were bridged over to the current chain.
    /// @param assets The assets bridged over from a source chain.
    function receiveFunds(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets) external;

    /// @notice Handle receiving of a message from a source chain.
    /// @param sourceChainId The chain from which the message was sent from.
    /// @param message The message that was sent from a source chain.
    function receiveMessage(uint256 sourceChainId, bytes memory message) external;
}
