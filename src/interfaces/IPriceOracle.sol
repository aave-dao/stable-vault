// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IPriceOracle
/// @author Aave Labs
/// @notice Interface for the Master Price Oracle contract.
interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256 price);

    function getPrices(address[] calldata assets) external view returns (uint256[] memory prices);

    function validatePrice(address asset) external view;
}
