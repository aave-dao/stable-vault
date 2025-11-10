// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ITransferHelper {
    /// @notice Allows the caller to pull assets from the contract. Essentially, to do transfers from the contract to
    /// the caller.
    /// @param assets The assets to pull. Zero for native currency.
    /// @param amounts The amount of each asset to pull.
    function pull(address[] memory assets, uint256[] memory amounts) external payable;

    /// @notice Allows the caller to transfer assets from the contract to the specified destination address.
    /// @param assets The assets to transfer. Zero for native currency.
    /// @param amounts The amount of each asset to transfer.
    /// @param destination The destination address to transfer all the assets to.
    function transfer(address[] memory assets, uint256[] memory amounts, address destination) external payable;

    /// @notice Allows the caller to transfer assets from the contract to each specified destination address.
    /// @param assets The assets to transfer. Zero for native currency.
    /// @param amounts The amount of each asset to transfer.
    /// @param destinations The destination addresses to transfer each of the assets to.
    function transfer(address[] memory assets, uint256[] memory amounts, address[] memory destinations) external payable;

    /// @notice Allows the caller to get the balance of an asset in the contract.
    /// @param asset The asset to get the balance of. Zero for native currency.
    /// @return The balance of the asset in the contract.
    function getBalance(address asset) external view returns (uint256);
}
