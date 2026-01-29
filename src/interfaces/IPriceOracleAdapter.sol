// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IPriceOracleAdapter
/// @author Aave Labs
/// @notice Interface for the Price Oracle Adapter contract that fetches price data for a single asset from an
/// underlying oracle.
interface IPriceOracleAdapter {
    // TODO: Should the interfaces be defined and taken from the IPriceOracle instead of from the adapter?
    // It seems that IPriceOracle is our main component, and the adapters should "adapt" to it, not the other way
    // around.
    struct OracleResponse {
        uint256 priceRay;
        bool isStale;
    }

    error StalePrice();
    error InvalidPrice();

    // TODO: do we need to pass in asset if the adapter is asset specific?
    // > Yes, just in case we want to re-use the adapter for multiple assets in some impl!
    function getPrice(address asset) external view returns (OracleResponse memory);

    // function getPrices(address[] calldata assets) external view returns (OracleResponse[] memory);
}
