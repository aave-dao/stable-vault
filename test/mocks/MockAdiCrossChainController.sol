// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {IAdiCrossChainForwarder} from "src/interfaces/IAdiCrossChainForwarder.sol";

contract MockAdiCrossChainController is IAdiCrossChainForwarder {
    error ForwardMessageFailed();

    uint256 public lastDestinationChainId;
    address public lastDestination;
    uint256 public lastGasLimit;
    bytes internal _lastMessage;
    bool internal _shouldRevertForwardMessage;

    receive() external payable {}

    function forwardMessage(uint256 destinationChainId, address destination, uint256 gasLimit, bytes calldata message)
        external
        override
        returns (bytes32 envelopeId, bytes32 transactionId)
    {
        require(!_shouldRevertForwardMessage, ForwardMessageFailed());
        lastDestinationChainId = destinationChainId;
        lastDestination = destination;
        lastGasLimit = gasLimit;
        _lastMessage = message;
        return (bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function setShouldRevertForwardMessage(bool shouldRevertForwardMessage) external {
        _shouldRevertForwardMessage = shouldRevertForwardMessage;
    }

    function getLastMessage() external view returns (bytes memory) {
        return _lastMessage;
    }

    function deliver(address receiver, address originSender, uint256 originChainId, bytes memory message) external {
        AdiAdapter(receiver).receiveCrossChainMessage(originSender, originChainId, message);
    }
}
