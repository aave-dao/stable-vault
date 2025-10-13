// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IWithdrawalPriorityQueue {
    function canBeExecuted(uint256 withdrawalRequestId) external view returns (bool);
}
