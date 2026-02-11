// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";

/// @title IChainBalanceOracleAdapter
/// @author Aave Labs
/// @notice Interface for the Chain Balance Oracle Adapter contract that fetches chain aggregated balance value from an
/// underlying data source.
interface IChainBalanceOracleAdapter {
    /// @notice Thrown when the chain id is not what was expected.
    /// @custom:selector 0x331003b3
    error InvalidChainId(uint256 chainId);

    /// @notice Thrown when the version of the IEarningChainState struct is not what was expected.
    /// @custom:selector 0xf680bfbb
    error InvalidEarningChainStateVersion(uint256 expected, uint256 actual);

    /// @notice Calls a configured data source to fetch the aggregated balance on a given chain.
    /// @dev This function does not validate the data returned by reverting, it relies on the ChainBalanceOracle
    /// contract to validate the data and revert if it is invalid.
    /// @param chainId The chain id to get the aggregated balance from the data source.
    /// @return ChainBalance
    function getChainBalance(uint256 chainId) external view returns (IChainBalanceOracle.ChainBalance memory);
}
