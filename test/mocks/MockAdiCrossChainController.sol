// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {IAdiCrossChainForwarder} from "src/interfaces/IAdiCrossChainForwarder.sol";

contract MockAdiCrossChainController is IAdiCrossChainForwarder {
    error ForwardMessageFailed();
    error UnexpectedQuoteGasLimit();
    error UnexpectedQuoteBandwidth();

    uint256 public lastDestinationChainId;
    address public lastDestination;
    uint256 public lastGasLimit;
    uint256 public forwardMessageCallCount;
    uint256 public forwardMessageStrictCallCount;
    uint256 public retryEnvelopeCallCount;
    uint256 public retryTransactionCallCount;
    uint256 public nativeFee;
    uint256 public successfulQuotes = 1;
    uint256 internal _optimalBandwidth;
    uint256 internal _expectedQuoteGasLimit;
    uint256 internal _expectedQuoteBandwidth;
    bool internal _shouldValidateQuote;
    bytes internal _lastMessage;
    IAdiCrossChainForwarder.Fee[] internal _fees;
    bool internal _shouldRevertForwardMessage;

    receive() external payable {}

    function forwardMessage(uint256 destinationChainId, address destination, uint256 gasLimit, bytes calldata message)
        external
        override
        returns (bytes32 envelopeId, bytes32 transactionId)
    {
        forwardMessageCallCount++;
        _recordForwardMessage(destinationChainId, destination, gasLimit, message);
        return (bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function forwardMessageStrict(
        uint256 destinationChainId,
        address destination,
        uint256 gasLimit,
        bytes calldata message
    ) external override returns (bytes32 envelopeId, bytes32 transactionId, uint256 forwardingSuccesses) {
        forwardMessageStrictCallCount++;
        _recordForwardMessage(destinationChainId, destination, gasLimit, message);
        return (bytes32(uint256(1)), bytes32(uint256(2)), 1);
    }

    function quoteForwardMessage(uint256, address, uint256 gasLimit, bytes calldata, uint256 quoteBandwidth)
        external
        view
        override
        returns (uint256, IAdiCrossChainForwarder.Fee[] memory, uint256)
    {
        if (_shouldValidateQuote) {
            require(gasLimit == _expectedQuoteGasLimit, UnexpectedQuoteGasLimit());
            require(quoteBandwidth == _expectedQuoteBandwidth, UnexpectedQuoteBandwidth());
        }

        IAdiCrossChainForwarder.Fee[] memory quotedFees = new IAdiCrossChainForwarder.Fee[](_fees.length);
        for (uint256 i = 0; i < _fees.length; i++) {
            quotedFees[i] = _fees[i];
        }
        return (nativeFee, quotedFees, successfulQuotes);
    }

    function quoteRetryEnvelope(IAdiCrossChainForwarder.Envelope calldata, uint256 gasLimit, uint256 quoteBandwidth)
        external
        view
        override
        returns (uint256, IAdiCrossChainForwarder.Fee[] memory, uint256)
    {
        if (_shouldValidateQuote) {
            require(gasLimit == _expectedQuoteGasLimit, UnexpectedQuoteGasLimit());
            require(quoteBandwidth == _expectedQuoteBandwidth, UnexpectedQuoteBandwidth());
        }

        return (nativeFee, _copyFees(), successfulQuotes);
    }

    function quoteRetryTransaction(bytes calldata, uint256 gasLimit, address[] calldata)
        external
        view
        override
        returns (uint256, IAdiCrossChainForwarder.Fee[] memory, uint256)
    {
        if (_shouldValidateQuote) {
            require(gasLimit == _expectedQuoteGasLimit, UnexpectedQuoteGasLimit());
        }

        return (nativeFee, _copyFees(), successfulQuotes);
    }

    function getOptimalBandwidthByChain(uint256) external view override returns (uint256) {
        return _optimalBandwidth;
    }

    function retryEnvelope(IAdiCrossChainForwarder.Envelope calldata envelope, uint256 gasLimit)
        external
        override
        returns (bytes32 transactionId)
    {
        retryEnvelopeCallCount++;
        _recordRetryEnvelope(envelope, gasLimit);
        return bytes32(uint256(3));
    }

    function retryTransaction(bytes calldata encodedTransaction, uint256 gasLimit, address[] calldata)
        external
        override
    {
        retryTransactionCallCount++;
        IAdiCrossChainForwarder.Transaction memory transaction =
            abi.decode(encodedTransaction, (IAdiCrossChainForwarder.Transaction));
        IAdiCrossChainForwarder.Envelope memory envelope =
            abi.decode(transaction.encodedEnvelope, (IAdiCrossChainForwarder.Envelope));
        _recordRetryEnvelope(envelope, gasLimit);
    }

    function setNativeFee(uint256 newNativeFee) external {
        nativeFee = newNativeFee;
    }

    function setSuccessfulQuotes(uint256 newSuccessfulQuotes) external {
        successfulQuotes = newSuccessfulQuotes;
    }

    function setOptimalBandwidth(uint256 newOptimalBandwidth) external {
        _optimalBandwidth = newOptimalBandwidth;
    }

    function setExpectedQuote(uint256 gasLimit, uint256 quoteBandwidth) external {
        _expectedQuoteGasLimit = gasLimit;
        _expectedQuoteBandwidth = quoteBandwidth;
        _shouldValidateQuote = true;
    }

    function setFees(address[] calldata tokens, uint256[] calldata amounts) external {
        require(tokens.length == amounts.length, "LENGTH_MISMATCH");
        delete _fees;
        for (uint256 i = 0; i < tokens.length; i++) {
            _fees.push(IAdiCrossChainForwarder.Fee({token: tokens[i], amount: amounts[i]}));
        }
    }

    function setShouldRevertForwardMessage(bool shouldRevertForwardMessage) external {
        _shouldRevertForwardMessage = shouldRevertForwardMessage;
    }

    function getLastMessage() external view returns (bytes memory) {
        return _lastMessage;
    }

    function deliver(
        address receiver,
        address originSender,
        uint256 originChainId,
        bytes memory message,
        bytes32 envelopeId
    ) external {
        AdiAdapter(receiver).receiveCrossChainMessage(originSender, originChainId, message, envelopeId);
    }

    function _recordForwardMessage(
        uint256 destinationChainId,
        address destination,
        uint256 gasLimit,
        bytes calldata message
    ) internal {
        require(!_shouldRevertForwardMessage, ForwardMessageFailed());
        lastDestinationChainId = destinationChainId;
        lastDestination = destination;
        lastGasLimit = gasLimit;
        _lastMessage = message;
    }

    function _recordRetryEnvelope(IAdiCrossChainForwarder.Envelope memory envelope, uint256 gasLimit) internal {
        require(!_shouldRevertForwardMessage, ForwardMessageFailed());
        lastDestinationChainId = envelope.destinationChainId;
        lastDestination = envelope.destination;
        lastGasLimit = gasLimit;
        _lastMessage = envelope.message;
    }

    function _copyFees() internal view returns (IAdiCrossChainForwarder.Fee[] memory quotedFees) {
        quotedFees = new IAdiCrossChainForwarder.Fee[](_fees.length);
        for (uint256 i = 0; i < _fees.length; i++) {
            quotedFees[i] = _fees[i];
        }
    }
}
