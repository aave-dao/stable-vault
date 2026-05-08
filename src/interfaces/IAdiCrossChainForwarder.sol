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

    /// @notice a.DI envelope routing data.
    /// @param nonce Envelope nonce assigned by a.DI.
    /// @param origin Origin sender on the source chain.
    /// @param destination Destination receiver on the destination chain.
    /// @param originChainId Source chain id.
    /// @param destinationChainId Destination chain id.
    /// @param message Message payload to bridge.
    struct Envelope {
        uint256 nonce;
        address origin;
        address destination;
        uint256 originChainId;
        uint256 destinationChainId;
        bytes message;
    }

    /// @notice a.DI transaction wrapping an encoded envelope.
    /// @param nonce Transaction nonce assigned by a.DI.
    /// @param encodedEnvelope ABI-encoded a.DI envelope.
    struct Transaction {
        uint256 nonce;
        bytes encodedEnvelope;
    }

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

    /// @notice Forwards a message through a.DI and reverts unless enough source-side adapter sends succeed.
    /// @param destinationChainId Chain id of the destination chain.
    /// @param destination Receiver portal on the destination chain.
    /// @param gasLimit Gas cost on receiving side of the message.
    /// @param message Message payload to bridge.
    /// @return envelopeId a.DI envelope id.
    /// @return transactionId a.DI transaction id.
    /// @return forwardingSuccesses Number of successful source-side bridge adapter sends.
    function forwardMessageStrict(
        uint256 destinationChainId,
        address destination,
        uint256 gasLimit,
        bytes calldata message
    ) external returns (bytes32 envelopeId, bytes32 transactionId, uint256 forwardingSuccesses);

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

    /// @notice Quotes the funding required to retry a registered envelope as a new a.DI transaction.
    /// @param envelope a.DI envelope to retry.
    /// @param gasLimit Gas cost on receiving side of the message.
    /// @param quoteBandwidth Number of adapters to quote. Zero quotes all configured adapters.
    /// @return nativeFee Native funding required by the selected a.DI adapter set.
    /// @return fees ERC20 funding required by the selected a.DI adapter set.
    /// @return successfulQuotes Number of selected bridge adapters that quoted successfully.
    function quoteRetryEnvelope(Envelope calldata envelope, uint256 gasLimit, uint256 quoteBandwidth)
        external
        view
        returns (uint256 nativeFee, Fee[] memory fees, uint256 successfulQuotes);

    /// @notice Quotes the funding required to retry an already forwarded a.DI transaction.
    /// @param encodedTransaction ABI-encoded a.DI transaction to retry.
    /// @param gasLimit Gas cost on receiving side of the message.
    /// @param bridgeAdaptersToRetry Current-chain a.DI bridge adapters to retry.
    /// @return nativeFee Native funding required by the selected a.DI adapter set.
    /// @return fees ERC20 funding required by the selected a.DI adapter set.
    /// @return successfulQuotes Number of selected bridge adapters that quoted successfully.
    function quoteRetryTransaction(
        bytes calldata encodedTransaction,
        uint256 gasLimit,
        address[] calldata bridgeAdaptersToRetry
    ) external view returns (uint256 nativeFee, Fee[] memory fees, uint256 successfulQuotes);

    /// @notice Retries a registered envelope as a new a.DI transaction.
    /// @param envelope a.DI envelope to retry.
    /// @param gasLimit Gas cost on receiving side of the message.
    /// @return transactionId a.DI transaction id for the retry.
    function retryEnvelope(Envelope calldata envelope, uint256 gasLimit) external returns (bytes32 transactionId);

    /// @notice Retries an already forwarded a.DI transaction.
    /// @param encodedTransaction ABI-encoded a.DI transaction to retry.
    /// @param gasLimit Gas cost on receiving side of the message.
    /// @param bridgeAdaptersToRetry Current-chain a.DI bridge adapters to retry.
    function retryTransaction(
        bytes calldata encodedTransaction,
        uint256 gasLimit,
        address[] calldata bridgeAdaptersToRetry
    ) external;
}
