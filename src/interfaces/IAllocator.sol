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

    error VaultIsDefault();
    error NonZeroVaultBalance();
    error UnsupportedVault(address asset, address vault);

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

    function getManager() external view returns (address);

    function getAdmin() external view returns (address);

    /// @dev Returns an array of balances where each amount is denominated in the corresponding asset's decimals.
    function getAssetBalances() external view returns (AllocatorBalance[] memory);

    /// @dev Returns the available liquidity denominated in given asset's decimals.
    function getAssetBalance(address asset) external view returns (uint256);

    /// @dev Returns strategy vault for a given asset.
    function getDefaultVault(address asset) external view returns (address);

    /// @dev Returns if a given vault is allowed to be allocated to or deallocated from for a given asset.
    function isAllowedVault(address asset, address vault) external view returns (bool);

    /// @dev Deallocates a given amount of an asset from the immediate liquidity vault; funds stay idle on the contract.
    /// @param asset Asset to deallocate.
    /// @param amount Amount of the asset to deallocate.
    /// @param vault Vault to deallocate from.
    /// @dev Returns the amount of shares burned liquidty source vault shares burned.
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

    function withdraw(address asset, uint256 amount) external;

    function setManager(address newManager) external;

    /// @dev Toggles if `depositor` can call deposit functions on the contract.
    function setDepositor(address depositor, bool whitelisted) external;

    /// @dev Toggles if `withdrawer` can call withdraw functions on the contract.
    function setWithdrawer(address withdrawer, bool whitelisted) external;

    function setVault(address asset, address vault, bool isAllowed) external;

    function setDefaultVault(address asset, address vault) external;
}
