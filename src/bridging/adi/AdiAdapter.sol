// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {Envelope, Transaction} from "aave-delivery-infrastructure/contracts/libs/EncodingUtils.sol";

import {BaseBridgeAdapter} from "src/bridging/BaseBridgeAdapter.sol";
import {IAdiBridgeAdapter} from "src/interfaces/IAdiBridgeAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {RescuableNative} from "src/misc/RescuableNative.sol";
import {RescuableToken} from "src/misc/RescuableToken.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title AdiAdapter
/// @author Aave Labs
/// @notice Adapter for sending and receiving data-only messages via a.DI.
contract AdiAdapter is BaseBridgeAdapter, RescuableNative, RescuableToken, IAdiBridgeAdapter {
    using SafeERC20 for IERC20;

    /// @dev Additional gas a.DI should allocate for this adapter before entering the destination Gateway.
    /// The current mocked Gateway trace measures the adapter wrapper at about 7.2k gas. Rounded up to 10k for
    /// calldata growth and cold access variance.
    uint256 internal constant DATA_ONLY_RECEIVE_GAS_OVERHEAD = 10_000;

    address internal immutable ADI_CROSS_CHAIN_CONTROLLER;

    modifier onlyCrossChainController() {
        require(msg.sender == ADI_CROSS_CHAIN_CONTROLLER, OnlyCrossChainController());
        _;
    }

    constructor(address accessManager, address gateway, address crossChainController, address transferHelper)
        BaseBridgeAdapter(accessManager, gateway, transferHelper)
    {
        require(crossChainController != address(0), Errors.ZeroAddress());
        ADI_CROSS_CHAIN_CONTROLLER = crossChainController;
    }

    /// @inheritdoc IAdiBridgeAdapter
    function getCrossChainController() external view override returns (address crossChainController) {
        return ADI_CROSS_CHAIN_CONTROLLER;
    }

    /// @inheritdoc IBridgeAdapter
    function getDataOnlyReceiveGasOverhead()
        public
        pure
        override(BaseBridgeAdapter, IBridgeAdapter)
        returns (uint256 gasOverhead)
    {
        return DATA_ONLY_RECEIVE_GAS_OVERHEAD;
    }

    /// @inheritdoc IAdiBridgeAdapter
    function quoteMessageToChain(uint256 destinationChainId, bytes calldata messageData, uint256 gasLimit)
        external
        view
        override
        returns (uint256 nativeFee, ICrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes)
    {
        address destinationChainAdapter = _destinationChainAdapterOf[destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());

        return _quoteForwardMessage(destinationChainId, destinationChainAdapter, gasLimit, messageData);
    }

    /// @inheritdoc IBridgeAdapter
    function publishDataOnlyMessage(
        uint256 destinationChainId,
        bytes memory messageData,
        address feePayer,
        uint256 payloadExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        require(feePayer != address(0), Errors.ZeroAddress());
        require(bridgeAdapterData.length == 0, Errors.InvalidParameter());

        address destinationChainAdapter = _destinationChainAdapterOf[destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());
        require(
            ICrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER).getRequiredForwardingSuccessesByChain(destinationChainId)
                > 0,
            RequiredForwardingSuccessesNotSet()
        );

        uint256 adjustedGasLimit = _withReceiverOverhead(payloadExecutionGasLimit);
        (uint256 nativeFee, ICrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes) =
            _quoteForwardMessage(destinationChainId, destinationChainAdapter, payloadExecutionGasLimit, messageData);
        require(successfulQuotes > 0, NoSuccessfulQuotes());
        _fundCrossChainController(feePayer, nativeFee, fees);

        (bytes32 envelopeId,) = ICrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER)
            .forwardMessage(destinationChainId, destinationChainAdapter, adjustedGasLimit, messageData);
        emit MessagePublished(envelopeId);

        _refundExcessNative(feePayer, nativeFee);
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageWithFunds(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory messageData,
        address feePayer,
        uint256 receiverExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        (destinationChainId, amount, messageData, feePayer, receiverExecutionGasLimit, bridgeAdapterData);
        revert Errors.UnsupportedAsset(asset);
    }

    /// @inheritdoc IAdiBridgeAdapter
    function quoteRetryTransaction(
        bytes calldata encodedTransaction,
        uint256 gasLimit,
        address[] calldata bridgeAdaptersToRetry
    )
        external
        view
        override
        returns (uint256 nativeFee, ICrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes)
    {
        Envelope memory envelope = _decodeTransactionEnvelope(encodedTransaction);
        _validateRetryEnvelope(envelope);

        return ICrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER)
            .quoteRetryTransaction(encodedTransaction, _withReceiverOverhead(gasLimit), bridgeAdaptersToRetry);
    }

    /// @inheritdoc IAdiBridgeAdapter
    /// @notice `msg.sender` funds the retry. ERC-20 fee approvals must be granted to this adapter contract, with each
    /// fee token's allowance limited to the expected fee rather than unlimited: the adapter pulls the quoted fees with
    /// no per-transaction bound, so limited allowances cap the worst case if a fee quoter returns over-stated fees.
    function retryTransaction(
        bytes calldata encodedTransaction,
        uint256 gasLimit,
        address[] calldata bridgeAdaptersToRetry
    ) external payable override {
        Envelope memory envelope = _decodeTransactionEnvelope(encodedTransaction);
        _validateRetryEnvelope(envelope);

        uint256 adjustedGasLimit = _withReceiverOverhead(gasLimit);
        (uint256 nativeFee, ICrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes) = ICrossChainForwarder(
                ADI_CROSS_CHAIN_CONTROLLER
            ).quoteRetryTransaction(encodedTransaction, adjustedGasLimit, bridgeAdaptersToRetry);
        require(successfulQuotes > 0, NoSuccessfulQuotes());
        _fundCrossChainController(msg.sender, nativeFee, fees);

        ICrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER)
            .retryTransaction(encodedTransaction, adjustedGasLimit, bridgeAdaptersToRetry);
        emit MessageRetried(_getEnvelopeId(envelope), _getTransactionId(encodedTransaction));

        _refundExcessNative(msg.sender, nativeFee);
    }

    /// @inheritdoc IAdiBridgeAdapter
    function quoteRetryEnvelope(Envelope calldata envelope, uint256 gasLimit, uint256 quoteBandwidth)
        external
        view
        override
        returns (uint256 nativeFee, ICrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes)
    {
        _validateRetryEnvelope(envelope);

        return ICrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER)
            .quoteRetryEnvelope(envelope, _withReceiverOverhead(gasLimit), quoteBandwidth);
    }

    /// @inheritdoc IAdiBridgeAdapter
    /// @notice `msg.sender` funds the retry. ERC-20 fee approvals must be granted to this adapter contract, with each
    /// fee token's allowance limited to the expected fee rather than unlimited: the adapter pulls the quoted fees with
    /// no per-transaction bound, so limited allowances cap the worst case if a fee quoter returns over-stated fees.
    function retryEnvelope(Envelope calldata envelope, uint256 gasLimit)
        external
        payable
        override
        returns (bytes32 transactionId)
    {
        _validateRetryEnvelope(envelope);

        uint256 adjustedGasLimit = _withReceiverOverhead(gasLimit);
        uint256 quoteBandwidth =
            ICrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER).getOptimalBandwidthByChain(envelope.destinationChainId);
        (uint256 nativeFee, ICrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes) = ICrossChainForwarder(
                ADI_CROSS_CHAIN_CONTROLLER
            ).quoteRetryEnvelope(envelope, adjustedGasLimit, quoteBandwidth);
        require(successfulQuotes > 0, NoSuccessfulQuotes());
        _fundCrossChainController(msg.sender, nativeFee, fees);

        transactionId = ICrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER).retryEnvelope(envelope, adjustedGasLimit);
        emit MessageRetried(_getEnvelopeId(envelope), transactionId);

        _refundExcessNative(msg.sender, nativeFee);
    }

    /// @inheritdoc IAdiBridgeAdapter
    function receiveCrossChainMessage(
        address originSender,
        uint256 originChainId,
        bytes calldata message,
        bytes32 envelopeId
    ) external override onlyCrossChainController {
        address trustedOriginSender = _destinationChainAdapterOf[originChainId];
        require(trustedOriginSender != address(0), Errors.InvalidParameter());
        require(originSender == trustedOriginSender, OnlyDestinationChainAdapter());

        IChainGateway(GATEWAY).receiveMessage(originChainId, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, message);
        emit MessageReceived(envelopeId);
    }

    function _quoteForwardMessage(
        uint256 destinationChainId,
        address destinationChainAdapter,
        uint256 gasLimit,
        bytes memory data
    ) internal view returns (uint256 nativeFee, ICrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes) {
        ICrossChainForwarder crossChainForwarder = ICrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER);
        uint256 quoteBandwidth = crossChainForwarder.getOptimalBandwidthByChain(destinationChainId);
        return crossChainForwarder.quoteForwardMessage(
            destinationChainId, destinationChainAdapter, _withReceiverOverhead(gasLimit), data, quoteBandwidth
        );
    }

    function _decodeTransactionEnvelope(bytes calldata encodedTransaction)
        internal
        pure
        returns (Envelope memory envelope)
    {
        Transaction memory transaction = abi.decode(encodedTransaction, (Transaction));
        return abi.decode(transaction.encodedEnvelope, (Envelope));
    }

    function _validateRetryEnvelope(Envelope memory envelope) internal view {
        address destinationChainAdapter = _destinationChainAdapterOf[envelope.destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());
        require(envelope.origin == address(this), Errors.InvalidParameter());
        require(envelope.originChainId == block.chainid, Errors.InvalidParameter());
        require(envelope.destination == destinationChainAdapter, Errors.InvalidParameter());
    }

    function _getEnvelopeId(Envelope memory envelope) internal pure returns (bytes32) {
        return keccak256(abi.encode(envelope));
    }

    function _getTransactionId(bytes calldata encodedTransaction) internal pure returns (bytes32) {
        return keccak256(encodedTransaction);
    }

    /// @dev Funds the CCC with the full quoted fee before forwarding. a.DI never refunds, so the quoted fee for any
    /// leg that fails to send stays in the CCC; `_refundExcessNative` only returns native paid above the quote.
    /// Leftovers are recoverable by the CCC owner.
    function _fundCrossChainController(address feePayer, uint256 nativeFee, ICrossChainForwarder.Fee[] memory fees)
        internal
    {
        require(msg.value >= nativeFee, Errors.InsufficientFunds());

        if (nativeFee > 0) {
            (bool callSucceeded,) = payable(ADI_CROSS_CHAIN_CONTROLLER).call{value: nativeFee}("");
            require(callSucceeded, Errors.NativeTransferFailed());
        }

        // a.DI merges duplicate ERC20 fee tokens before returning quotes, so this loop intentionally does not dedup.
        for (uint256 i = 0; i < fees.length; i++) {
            require(fees[i].token != address(0), Errors.InvalidParameter());
            require(fees[i].token != Constants.NATIVE_CURRENCY, Errors.InvalidParameter());
            if (fees[i].amount > 0) {
                IERC20(fees[i].token).safeTransferFrom(feePayer, ADI_CROSS_CHAIN_CONTROLLER, fees[i].amount);
            }
        }
    }

    function _refundExcessNative(address feePayer, uint256 nativeFee) internal {
        uint256 excessNative = msg.value - nativeFee;
        if (excessNative > 0) {
            (bool callSucceeded,) = payable(feePayer).call{value: excessNative}("");
            require(callSucceeded, Errors.NativeTransferFailed());
        }
    }

    function _beforeRescueNative(uint256) internal virtual override {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }

    function _beforeRescueTokens(address, uint256) internal virtual override {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }
}
