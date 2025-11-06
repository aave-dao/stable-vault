// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev Assumes single strategy per asset; multiple assets per Allocator.
/// @dev Deals with assets in their native decimals.
interface IAllocator {
    event AssetDeallocated(address indexed asset, address indexed vault, uint256 amount, uint256 burnedShares);
    /// @notice emitted when funds fails to deposit to strategy vault and left idle in Allocator.
    event VaultDepositFailed(address indexed vault, uint256 amount);
    event VaultAdded(address indexed asset, address indexed vault);
    event VaultRemoved(address indexed asset, address indexed vault);
    event DefaultVaultSet(address indexed asset, address indexed vault);

    error NonZeroVaultBalance();

    struct AllocatorBalance {
        address asset;
        uint256 amount;
    }

    struct SwapParams {
        // Swap input asset transferred to swapper
        address assetIn;
        // Asset to swap to that will be resupplied within the allocator
        address assetOut;
        // Amount of assetIn
        uint256 amountIn;
        // Address of the swapper to use to execute the swap
        address swapper;
        // Custom data required by the swapper to execute the swap
        bytes swapData;
    }

    struct CrossAssetRebalanceParams {
        SwapParams[] swaps;
    }

    /// @dev Returns an array of balances where each amount is denominated in the corresponding asset's decimals.
    function getAssetBalances() external view returns (AllocatorBalance[] memory);

    /// @dev Returns strategy vault for a given asset.
    function getDefaultVault(address asset) external view returns (address);

    /// @dev Returns if a given vault is supported for allocating to or deallocating from a given asset.
    function isVaultSupportedForAsset(address asset, address vault) external view returns (bool);

    /// @dev Returns if a given vault is supported for allocating or deallocating, regardless of the asset.
    function isVaultSupported(address vault) external view returns (bool);

    /// @dev Deallocates a given amount of an asset from the immediate liquidity vault; funds stay idle on the contract.
    /// @param asset Asset to deallocate.
    /// @param amount Amount of the asset to deallocate. Zero to deallocate the maximum possible amount.
    /// @param vault Vault to deallocate from.
    /// @dev Returns the amount of shares burned liquidity source vault shares burned.
    function deallocate(address asset, uint256 amount, address vault) external returns (uint256);

    /// @notice Moves all idle funds of a given asset on the contract to a strategy.
    function depositIdleFunds(address asset) external;

    function deposit(address asset, uint256 amount) external;

    /// @notice Rebalance the mix of underlying tokens by pulling from strategies, executing swaps and resupplying to
    /// strategies.
    /// @dev Swapping is only performed on idle balances or assets in the default strategy vault.
    function rebalance(CrossAssetRebalanceParams memory params) external;

    /// @notice Reallocates a given amount of an asset from one vault to another.
    /// @param asset Asset to reallocate.
    /// @param amount Amount of the asset expected to be reallocated.
    /// @param fromVault Vault to deallocate from.
    /// @param toVault Vault to allocate to.
    function reallocate(address asset, uint256 amount, address fromVault, address toVault) external;

    /// @notice Withdraws a given amount of an asset from the immediate liquidity vault a.k.a the default strategy vault
    /// for the asset. @param asset Asset to withdraw.
    /// @param amount Amount of the asset to withdraw.
    function withdraw(address asset, uint256 amount) external;

    /// @notice Withdraws a given amount of an asset from a given strategy vault.
    /// @param asset Asset to withdraw.
    /// @param amount Amount of the asset to withdraw.
    /// @param strategyVault Address of the strategy vault to withdraw from.
    function withdrawFromStrategy(address asset, uint256 amount, address strategyVault) external;

    /// @dev Adds a new strategy vault to the allocator.
    /// @param asset The asset to add the vault for.
    /// @param vault The ERC-4626 vault address.
    function addVault(address asset, address vault) external;

    /// @dev Removes a strategy vault from the allocator.
    /// @param vault The ERC-4626 vault address to remove.
    function removeVault(address vault) external;

    /// @dev Sets the default strategy vault for an asset.
    /// @param asset The asset to set the default vault for.
    /// @param vault The ERC-4626 vault address to set as the default.
    function setDefaultVault(address asset, address vault) external;
}
