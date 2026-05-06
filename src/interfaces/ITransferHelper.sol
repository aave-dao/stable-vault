// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ITransferHelper
/// @author Aave Labs
/// @notice Interface for the TransferHelper contract.
interface ITransferHelper {
    /// @notice Allows the caller to pull assets from the contract. Essentially, to do transfers from the contract to
    /// the caller.
    /// @param assets The assets to pull. `address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)` for native currency.
    /// @param amounts The amount of each asset to pull.
    function pull(address[] memory assets, uint256[] memory amounts) external;

    /// @notice Allows the caller to pull an asset from the contract. Essentially, to do a transfer from the contract to
    /// the caller.
    /// @param asset The asset to pull. `address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)` for native currency.
    /// @param amount The amount of the asset to pull.
    function pull(address asset, uint256 amount) external;

    /// @notice Allows the caller to transfer assets from the contract to the specified destination address.
    /// @param assets The assets to transfer. `address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)` for native currency.
    /// @param amounts The amount of each asset to transfer.
    /// @param destination The destination address to transfer all the assets to.
    function transfer(address[] memory assets, uint256[] memory amounts, address destination) external;

    /// @notice Allows the caller to transfer assets from the contract to each specified destination address.
    /// @param assets The assets to transfer. `address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)` for native currency.
    /// @param amounts The amount of each asset to transfer.
    /// @param destinations The destination addresses to transfer each of the assets to.
    function transfer(address[] memory assets, uint256[] memory amounts, address[] memory destinations) external;

    /// @notice Allows the caller to transfer an asset from the contract to the specified destination address.
    /// @param asset The asset to transfer. `address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)` for native currency.
    /// @param amount The amount of the asset to transfer.
    /// @param destination The destination address to transfer the asset to.
    function transfer(address asset, uint256 amount, address destination) external;

    /// @notice Allows the caller to get the balance of an asset in the contract.
    /// @param asset The asset to query. `address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)` for native currency.
    /// @return The balance of the asset in the contract.
    function getBalance(address asset) external view returns (uint256);
}
