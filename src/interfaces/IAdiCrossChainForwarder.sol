// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IAdiCrossChainForwarder
/// @author Aave Labs
/// @notice Minimal interface for the a.DI CrossChainController forwarding surface.
interface IAdiCrossChainForwarder {
    /// @notice ERC20 fee required to forward a message through a.DI.
    /// @param token ERC20 token required to pay the fee.
    /// @param amount Amount of token required.
    struct Fee {
        address token;
        uint256 amount;
    }

    /// @notice Forwards a message through a.DI to a destination chain receiver portal.
    /// @dev a.DI enforces the configured required source-side forwarding successes before returning.
    /// @param destinationChainId Chain id of the destination chain.
    /// @param destination Receiver portal on the destination chain.
    /// @param gasLimit Gas cost on receiving side of the message.
    /// @param message Message payload to bridge.
    /// @return envelopeId a.DI envelope id.
    /// @return transactionId a.DI transaction id.
    function forwardMessage(uint256 destinationChainId, address destination, uint256 gasLimit, bytes calldata message)
        external
        returns (bytes32 envelopeId, bytes32 transactionId);

    /// @notice Returns the configured optimal forwarding bandwidth for a destination chain.
    /// @param chainId Chain id of the destination chain.
    /// @return optimalBandwidth Number of adapters a.DI will select. Zero means all configured adapters.
    function getOptimalBandwidthByChain(uint256 chainId) external view returns (uint256 optimalBandwidth);

    /// @notice Quotes the funding required to forward a message through a.DI.
    /// @param destinationChainId Chain id of the destination chain.
    /// @param destination Receiver portal on the destination chain.
    /// @param gasLimit Gas cost on receiving side of the message.
    /// @param message Message payload to bridge.
    /// @param quoteBandwidth Number of adapters to quote. Zero quotes all configured adapters.
    /// @return nativeFee Native funding required by the selected a.DI adapter set.
    /// @return fees ERC20 funding required by the selected a.DI adapter set.
    /// @return successfulQuotes Number of selected bridge adapters that quoted successfully.
    function quoteForwardMessage(
        uint256 destinationChainId,
        address destination,
        uint256 gasLimit,
        bytes calldata message,
        uint256 quoteBandwidth
    ) external view returns (uint256 nativeFee, Fee[] memory fees, uint256 successfulQuotes);
}
