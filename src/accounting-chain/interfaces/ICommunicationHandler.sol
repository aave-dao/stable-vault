// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ICommunicationHandler {
    error UnsupportedMessageType();
    error UnsupportedAdapter();
    error NotFundsHandler();
    error NotAdmin();


    enum MessageType {
        BALANCE_UPDATE,
        TRANSFER,
        PULL_FUNDS
    }

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId) external;

    function sendPullFundsFromChainMessage(uint256 amount, uint256 targetChainId) external;

    function receiveMessage(uint256 fromChainId, bytes calldata typeAndMessageEncoded) external;
}