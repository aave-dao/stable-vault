// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IAdiCrossChainForwarder
/// @author Aave Labs
/// @notice Minimal interface for the a.DI CrossChainController forwarding surface.
interface IAdiCrossChainForwarder {
    /// @notice Forwards a message through a.DI to a destination chain receiver portal.
    /// @param destinationChainId Chain id of the destination chain.
    /// @param destination Receiver portal on the destination chain.
    /// @param gasLimit Gas cost on receiving side of the message.
    /// @param message Message payload to bridge.
    /// @return envelopeId a.DI envelope id.
    /// @return transactionId a.DI transaction id.
    function forwardMessage(uint256 destinationChainId, address destination, uint256 gasLimit, bytes calldata message)
        external
        returns (bytes32 envelopeId, bytes32 transactionId);
}
