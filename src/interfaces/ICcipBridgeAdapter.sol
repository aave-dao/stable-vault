// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title ICcipBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the CcipBridgeAdapter contract.
interface ICcipBridgeAdapter is IBridgeAdapter {
    /// @notice Emitted when a CCIP chain selector mapping is set.
    event ChainSelectorSet(uint256 indexed chainId, uint64 indexed ccipChainSelector);

    /// @notice Emitted when excess bridge fees are refunded to the fee payer.
    event FeeRefunded(address indexed feePayer, address indexed feeToken, uint256 amount);

    /// @notice Thrown when the CCIP router did not fully consume the allowance granted for a token used in
    /// `ccipSend` (bridged asset or ERC-20 fee token). Indicates the router pulled less than approved, leaving
    /// residual approval that this adapter does not expect.
    /// @custom:selector 0x8d63b92b
    error UnexpectedCcipRouterAllowance(address token, uint256 remainingAllowance);

    /// @notice Encoded data length does not match the expected value.
    /// @custom:selector 0x9546c78e
    error UnexpectedDataLength();

    /// @notice Sets the Chainlink CCIP chain selector for a given chain id.
    /// @param chainId Chain id of the chain to set the Chainlink CCIP chain selector for.
    /// @param ccipChainSelector Chainlink CCIP chain selector to set for the chain id.
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external;

    /// @notice Triggers the receiving process for a given asset, allowing funds that got stuck
    /// in the adapter to be re-injected into the system.
    /// @param asset Asset to trigger the receiving process for.
    /// @param amount Amount of the asset to process and receive.
    function replayFundsReceiving(address asset, uint256 amount) external;

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
}
