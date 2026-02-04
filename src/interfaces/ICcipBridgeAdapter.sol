// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Client} from "lib/chainlink-ccip/chains/evm/contracts/libraries/Client.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title ICcipBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the CcipBridgeAdapter contract.
interface ICcipBridgeAdapter is IBridgeAdapter {
    /// @notice Thrown when the gas limit is insufficient for the CCIP defensive receiver.
    /// @custom:selector 0x4aa5d366
    error CCIPDefensiveReceiverInsufficientGas();

    /// @notice Thrown when the message is not retryable because it has already been processed or is not found.
    /// @custom:selector 0xdfb261cb
    error MessageNotRetryable(bytes32 messageId);

    /// @notice Encoded data length does not match the expected value.
    /// @custom:selector 0x9546c78e
    error UnexpectedDataLength();

    /// @notice Getter for the address of the Chainlink CCIP router.
    /// @return router Address of the Chainlink CCIP router.
    function getRouter() external view returns (address);

    /// @notice Getter for the Chainlink CCIP chain selector for a given chain id.
    /// @param chainId Chain id of the chain to get the Chainlink CCIP chain selector for.
    /// @return ccipChainSelector Chainlink CCIP chain selector for the given chain id.
    function getChainSelector(uint256 chainId) external view returns (uint64);

    /// @notice Getter for the chain id for a given Chainlink CCIP chain selector.
    /// @param ccipChainSelector Chainlink CCIP chain selector to get the chain id for.
    /// @return chainId Chain id for the given Chainlink CCIP chain selector.
    function getChainId(uint64 ccipChainSelector) external view returns (uint256);

    /// @notice Getter for a retryable message.
    /// @param messageId Message id of the message to get.
    /// @return message Retryable message.
    function getRetryableMessage(bytes32 messageId) external view returns (Client.Any2EVMMessage memory);

    /// @notice Retries the processing of a failed message that is stored on the adapter.
    /// @param messageId Message id of the message to retry.
    function retryMessage(bytes32 messageId) external;

    /// @notice Sets the Chainlink CCIP chain selector for a given chain id.
    /// @param chainId Chain id of the chain to set the Chainlink CCIP chain selector for.
    /// @param ccipChainSelector Chainlink CCIP chain selector to set for the chain id.
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external;
}
