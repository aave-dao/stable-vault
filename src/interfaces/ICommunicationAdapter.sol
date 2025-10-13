// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// TODO: This is for the accounting side only...?
interface ICommunicationAdapter {
    function pushFundsToChain(uint256 chainId, address asset, uint256 amount) external;
    function pullFundsFromChain(uint256 chainId, uint256 amount) external;
}
