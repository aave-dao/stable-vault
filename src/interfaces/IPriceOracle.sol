// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IPriceOracle
/// @author Aave Labs
/// @notice Interface for the Master Price Oracle contract.
interface IPriceOracle {
    /// @notice Thrown when minimum valid price is out of accepted range.
    /// @custom:selector 0x6dd066fe
    error InvalidMinPrice();

    /// @notice Thrown when a price obtained from an oracle for an asset is below a minimum valid price.
    /// @custom:selector 0xdbbbe822
    error PriceTooLow();

    /// @notice Thrown when the adapter for an asset is not found.
    /// @custom:selector 0x2a40cc73
    error OracleAdapterNotFound(address asset);

    /// @notice Thrown when a price obtained from an oracle for an asset was updated before a threshold timestamp.
    /// @custom:selector 0x19abf40e
    error StalePrice();

    /// @notice Emitted when an adapter is set for an asset.
    event OracleAdapterSet(address indexed asset, address indexed newAdapter, address indexed previousAdapter);

    /// @notice Queries an oracle adapter for the price of an asset.
    /// @param asset The asset to get the price for.
    /// @return uint256 price of the asset in ray units quoted in the underlying currency e.g. $USD.
    function getPrice(address asset) external view returns (uint256);

    /// @notice Queries an oracle adapter for data representing the prices of multiple assets.
    /// @param assets The assets to get the prices for.
    /// @return uint256[] representing the prices of the assets in ray units.
    function getPrices(address[] calldata assets) external view returns (uint256[] memory);

    /// @notice Validates the price of an asset is greater than or equal to a minimum valid price.
    /// @param asset The asset to validate the price for.
    function validatePrice(address asset) external view;
}
