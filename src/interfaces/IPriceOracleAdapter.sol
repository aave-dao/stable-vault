// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IPriceOracleAdapter
/// @author Aave Labs
/// @notice Interface for the Price Oracle Adapter contract that fetches price data for a single asset from an
/// underlying oracle.
interface IPriceOracleAdapter {
    /// @notice The representation of the response from the oracle adapter.
    /// @param priceRay The price of the asset in RAY units e.g. 1e27 for 1 USD, 9_995e23 for 0.9995 USD.
    /// @param isStale Whether the price is considered stale.
    struct OracleResponse {
        uint256 priceRay;
        bool isStale;
    }

    /// @notice Fetches the price of an asset from the underlying oracle.
    /// @dev This function does not validate the data returned by reverting, it relies on the PriceOracle contract
    /// to validate the data and revert if it is invalid.
    /// @param asset The asset to fetch the price for.
    /// @return OracleResponse The response from the oracle adapter.
    function getPrice(address asset) external view returns (OracleResponse memory);
}
