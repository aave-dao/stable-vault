// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


interface IAdapter {
    function pushFundsToChain(uint256 chainId, address asset, uint256 amount) external;   
    function pullFundsFromChain(uint256 amount) external;

    function sendMessage(uint256 targetChainId, bytes memory message) external;
    function sendFunds(uint256 targetChainId, address asset, uint256 amount, bytes memory message) external;
    function receiveBridgeMessage(uint256 fromChainId, bytes memory message) external;
}