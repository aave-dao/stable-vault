// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IPriceOracleAdapter
/// @author Aave Labs
/// @notice Interface for the Price Oracle Adapter contract that fetches price data for a single asset from an
/// underlying oracle.
interface IPriceOracleAdapter {
    struct OracleResponse {
        uint256 priceRay;
        bool isStale;
    }

    error StalePrice();
    error InvalidPrice();

    // TODO: do we need to pass in asset if the adapter is asset specific?
    function getPrice(address asset) external view returns (OracleResponse memory);

    // function getPrices(address[] calldata assets) external view returns (OracleResponse[] memory);
}
