// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAdiCrossChainForwarder} from "src/interfaces/IAdiCrossChainForwarder.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title IAdiBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the AdiAdapter contract.
interface IAdiBridgeAdapter is IBridgeAdapter {
    /// @notice a.DI returned no successful bridge adapter quotes for a message that would be published or retried.
    /// @custom:selector 0x207ea6be
    error NoSuccessfulQuotes();

    /// @notice Address checked is not the configured a.DI CrossChainController.
    /// @custom:selector 0xe632d197
    error OnlyCrossChainController();

    /// @notice Retries an already forwarded StableVault a.DI transaction using caller-provided funding.
    /// @param encodedTransaction ABI-encoded a.DI transaction to retry.
    /// @param gasLimit Gas limit requested for Gateway payload execution on the destination chain.
    /// @param bridgeAdaptersToRetry Current-chain a.DI bridge adapters to retry.
    function retryTransaction(
        bytes calldata encodedTransaction,
        uint256 gasLimit,
        address[] calldata bridgeAdaptersToRetry
    ) external payable;

    /// @notice Retries a registered StableVault a.DI envelope as a new transaction using caller-provided funding.
    /// @dev Uses the CrossChainController's configured optimal bandwidth for both the internal quote and retry.
    /// @param envelope a.DI envelope to retry.
    /// @param gasLimit Gas limit requested for Gateway payload execution on the destination chain.
    /// @return transactionId a.DI transaction id for the retry.
    function retryEnvelope(IAdiCrossChainForwarder.Envelope calldata envelope, uint256 gasLimit)
        external
        payable
        returns (bytes32 transactionId);

    /// @notice Receives a confirmed a.DI message from the configured CrossChainController.
    /// @param originSender Sender address on the origin chain.
    /// @param originChainId Chain id where the message originated.
    /// @param message Message payload bridged by a.DI.
    /// @param envelopeId a.DI envelope id.
    function receiveCrossChainMessage(
        address originSender,
        uint256 originChainId,
        bytes calldata message,
        bytes32 envelopeId
    ) external;

    /// @notice Getter for the address of the a.DI CrossChainController.
    /// @return crossChainController Address of the a.DI CrossChainController.
    function getCrossChainController() external view returns (address crossChainController);

    /// @notice Quotes the funding required to publish a data-only message through a.DI.
    /// @param destinationChainId Chain id of the destination chain.
    /// @param messageData Message payload to bridge.
    /// @param gasLimit Gas limit requested for Gateway payload execution on the destination chain.
    /// @return nativeFee Native funding required by a.DI.
    /// @return fees ERC20 funding required by a.DI.
    /// @return successfulQuotes Number of selected a.DI bridge adapters that quoted successfully.
    function quoteMessageToChain(uint256 destinationChainId, bytes calldata messageData, uint256 gasLimit)
        external
        view
        returns (uint256 nativeFee, IAdiCrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes);

    /// @notice Quotes the funding required to retry an already forwarded StableVault a.DI transaction.
    /// @param encodedTransaction ABI-encoded a.DI transaction to retry.
    /// @param gasLimit Gas limit requested for Gateway payload execution on the destination chain.
    /// @param bridgeAdaptersToRetry Current-chain a.DI bridge adapters to retry.
    /// @return nativeFee Native funding required by a.DI.
    /// @return fees ERC20 funding required by a.DI.
    /// @return successfulQuotes Number of selected a.DI bridge adapters that quoted successfully.
    function quoteRetryTransaction(
        bytes calldata encodedTransaction,
        uint256 gasLimit,
        address[] calldata bridgeAdaptersToRetry
    ) external view returns (uint256 nativeFee, IAdiCrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes);

    /// @notice Quotes the funding required to retry a registered StableVault a.DI envelope as a new transaction.
    /// @dev `quoteBandwidth` is intentionally caller-selected so off-chain callers can quote a custom adapter set, such
    /// as all configured adapters for a conservative estimate. `retryEnvelope` does not accept `quoteBandwidth`; it
    /// requotes using the CrossChainController's configured optimal bandwidth before funding and retrying.
    /// @param envelope a.DI envelope to retry.
    /// @param gasLimit Gas limit requested for Gateway payload execution on the destination chain.
    /// @param quoteBandwidth Number of adapters to quote. Zero quotes all configured adapters.
    /// @return nativeFee Native funding required by a.DI.
    /// @return fees ERC20 funding required by a.DI.
    /// @return successfulQuotes Number of selected a.DI bridge adapters that quoted successfully.
    function quoteRetryEnvelope(
        IAdiCrossChainForwarder.Envelope calldata envelope,
        uint256 gasLimit,
        uint256 quoteBandwidth
    ) external view returns (uint256 nativeFee, IAdiCrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes);
}
