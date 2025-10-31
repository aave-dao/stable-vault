// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ICcipBridgeAdapter {
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external;
    function setFeeToken(address feeToken) external;
}
