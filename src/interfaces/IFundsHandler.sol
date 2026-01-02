// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title IFundsHandler
/// @author Aave Labs
/// @notice Interface for the FundsHandler contract.
interface IFundsHandler {
    /// @notice Thrown when the caller is not the BasedBoostedVault.
    /// @custom:selector 0x93ce7047
    error OnlyBasedBoostedVault();

    /// @notice Emitted when the chain balance snapshot is received from a chain.
    /// @param chainId Chain id of the chain that the snapshot (and potentially funds) arrived from.
    /// @param amountRay Amount of total assets on the chain in RAY.
    /// @param nonce Nonce of the balance snapshot from the source chain.
    event ChainBalanceSnapshotReceived(uint256 chainId, uint256 amountRay, uint256 nonce);

    /// @notice Emitted when the chain balance snapshot is updated before pushing funds to a chain.
    /// @param chainId Chain id of the chain that funds are being pushed to.
    /// @param deltaAmountRay Amount of the asset to increment the chain balance snapshot by in RAY.
    event ChainBalanceSnapshotIncremented(uint256 chainId, uint256 deltaAmountRay);

    /// @notice Emitted when the chain balance snapshot is decremented when ingesting funds through a bridge adapter
    /// that is not used to communicate the total balance snapshot.
    /// @param chainId Chain id of the chain that the funds arrived from.
    /// @param deltaAmountRay Amount of the asset to decrement the chain balance snapshot by in RAY.
    event ChainBalanceSnapshotDecremented(uint256 chainId, uint256 deltaAmountRay);

    /// @notice The representation of an asset balance.
    /// @param asset Address of the asset.
    /// @param amountRay Amount of the asset in RAY.
    /// @param chainId Chain id of the chain that the balance is on.
    struct AssetBalance {
        address asset;
        uint256 amountRay;
        uint256 chainId;
    }

    /// @notice Getter for the total assets in the local Allocator and the Allocators on all Earning Chains.
    /// @return aggregatedBalance Total liquidity across all supported chains in RAY of supported asset denomination.
    function getAggregatedBalance() external view returns (uint256);

    /// @notice Getter for the asset specific and chain specific balances in the local Allocator and the Allocators on
    /// all Earning Chains.
    /// @return assetBalances Array of asset balances for all supported chains including the native chain.
    function getAssetBalances() external view returns (AssetBalance[] memory);

    /// @notice Forward a deposit to a liquidity source.
    /// @param asset Address of the asset to deposit.
    /// @param amount Amount of the asset to deposit.
    function processDeposit(address asset, uint256 amount) external;

    /// @notice Executes a withdrawal request by pulling funds from the liquidity source and allowing them to be
    /// returned to the recipient with the data passed to the request.
    /// @param asset Address of the asset to pull from liquidity sources
    /// @param amount Amount of the asset to pull from liquidity sources
    function processWithdrawal(address asset, uint256 amount) external;

    /// @notice Retrieves funds from liquidity source on native chain before pushing funds to another chain through the
    /// Gateway contract.
    /// @param asset Address of the asset to push to the Accounting Chain.
    /// @param amount Amount of the asset to push to the Accounting Chain.
    /// @param chainId Chain id of the Accounting Chain.
    /// @param bridgeParams The parameters for the bridge adapter.
    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable;

    /// @notice Updates the chain balance snapshot for a given chain.
    /// @param chainId Chain id of the chain that sent the balance update.
    /// @param snapshotBalanceRay Balance snapshot on the source chain in RAY of supported asset denomination.
    /// @param chainBalanceSnapshotNonce Nonce of the balance snapshot from the source chain.
    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 chainBalanceSnapshotNonce)
        external;

    /// @notice Callback function for when funds arrive from a chain.
    /// @param asset Address of the asset that arrived from the chain.
    /// @param amount Amount of the asset that arrived from the chain.
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external;

    /// @notice Callback function to decrement a chain balance snapshot.
    /// @param chainId Chain id of the chain that the balance snapshot was decremented on.
    /// @param amountRay Amount to decrement the balance snapshot by in RAY.
    function decrementChainBalanceSnapshotCallback(uint256 chainId, uint256 amountRay) external;
}
