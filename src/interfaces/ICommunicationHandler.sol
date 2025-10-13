// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ICommunicationHandler {
    error UnsupportedMessageType();
    error UnsupportedAdapter();
    error NotFundsHandler();
    error NotAdmin();

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId) external;

    function sendPullFundsFromChainMessage(uint256 amount, uint256 targetChainId) external;

    function receiveBalanceSnapshotMessage(uint256 fromChainId, uint256 balance, uint256 timestamp) external;

    function receiveFunds(uint256 fromChainId, address asset, uint256 amount) external;
}
