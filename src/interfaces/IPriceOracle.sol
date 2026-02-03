// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IPriceOracle
/// @author Aave Labs
/// @notice Interface for the Master Price Oracle contract.
interface IPriceOracle {
    /// @notice Emitted when an adapter is set for an asset.
    event OracleAdapterSet(address indexed asset, address indexed newAdapter, address indexed previousAdapter);

    /// @notice Thrown when checked minimum valid price is above 1 unit of the quote asset.
    /// @custom:selector 0x6dd066fe
    error InvalidMinPrice();

    function getPrice(address asset) external view returns (uint256 price);

    function getPrices(address[] calldata assets) external view returns (uint256[] memory prices);

    function validatePrice(address asset) external view;
}
