// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IEarningChainCommuniationAdapter {
    function sendFundsWithBalanceSnapshot(uint256 chainId, address asset, uint256 amount, uint256 snapshotBalance, uint256 snapshotTimestamp) external;
}
