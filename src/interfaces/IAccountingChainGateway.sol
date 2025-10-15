// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IAccountingChainGateway {
    error NotFundsHandler();

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId) external;

    function sendPullFundsFromChainMessage(uint256 amount, uint256 targetChainId) external;
}
