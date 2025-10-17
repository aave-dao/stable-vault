// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev Assumes single strategy per asset; multiple assets per Allocator.
/// @dev Deals with assets in their native decimals.
interface IAllocator {
    event AssetDeallocated(address indexed asset, address indexed vault, uint256 amount, uint256 burnedShares);
    /// @notice emitted when funds fails to deposit to strategy vault and left idle in Allocator.
    event VaultDepositFailed(address indexed vault, uint256 amount);

    struct AllocatorBalance {
        address asset;
        uint256 amount;
    }

    function getManager() external view returns (address);

    function getAdmin() external view returns (address);

    /// @dev Returns an array of balances where each amount is denominated in the corresponding asset's decimals.
    function getAssetBalances() external view returns (AllocatorBalance[] memory);

    /// @dev Returns the available liquidity denominated in given asset's decimals.
    function getAssetBalance(address asset) external view returns (uint256);

    /// @dev Returns the default liquidity vault for a given asset.
    function getImmediateLiquidityVault(address asset) external view returns (address);

    function deposit(address asset, uint256 amount) external;

    function withdraw(address asset, uint256 amount) external;

    /// @dev Request any asset from the allocator for a given amount; assumes allocator assets have common denomination.
    function withdrawEmergency(uint256 amount) external returns (address asset);

    function setManager(address newManager) external;

    function setDepositor(address depositor, bool whitelisted) external;
}
