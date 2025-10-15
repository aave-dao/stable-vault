// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "./IBridgeAdapter.sol";

/// @notice Interface for handling the communication between chains for bridging assets and data.
/// @dev Assumes bridged assets and bridged data can be handled independently of each other.
interface IChainGateway {
    /// @notice Struct for arbitrary data containing a balance snapshot from a source chain.
    struct BalanceSnapshot {
        // Cumulative balance of all tokens with common denomination in RAY.
        uint256 balance;
        uint256 timestamp;
    }

    /// @notice Handle receiving of a data and funds from a source chain.
    /// @param sourceChainId The chain from which the message was sent from.
    /// @param data The data that was sent from a source chain.
    /// @param assets The assets bridged over from a source chain.
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external;
}
