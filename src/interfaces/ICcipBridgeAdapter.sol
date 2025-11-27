// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title ICcipBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the CcipBridgeAdapter contract.
interface ICcipBridgeAdapter {
    /// @notice Returns the address of the Chainlink CCIP router.
    function getRouter() external view returns (address);

    /// @notice Returns the Chainlink CCIP chain selector for a given chain id.
    function getChainSelector(uint256 chainId) external view returns (uint64);

    /// @notice Returns the chain id for a given Chainlink CCIP chain selector.
    function getChainId(uint64 ccipChainSelector) external view returns (uint256);

    /// @notice Sets the Chainlink CCIP chain selector for a given chain id.
    /// @param chainId Chain id of the chain to set the Chainlink CCIP chain selector for.
    /// @param ccipChainSelector Chainlink CCIP chain selector to set for the chain id.
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external;
}
