// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title IFundsHandler
/// @author Aave Labs
/// @notice Interface for the FundsHandler contract.
interface IFundsHandler {
    /// @notice Thrown when the caller is not the StableVault.
    /// @custom:selector 0x93ce7047
    error OnlyStableVault();

    /// @notice Thrown when the chain id is already present in the Earning chain set.
    /// @custom:selector 0x148e7b23
    error ChainIdAlreadyPresent();

    /// @notice Thrown when the chain id can not be removed because it is not present in the Earning chain set.
    /// @custom:selector 0xa80e441d
    error ChainIdNotPresent();

    /// @notice Emitted when an earning chain is added.
    /// @param chainId Chain id of the earning chain that was added.
    event EarningChainAdded(uint256 chainId);

    /// @notice Emitted when an earning chain is removed.
    /// @param chainId Chain id of the earning chain that was removed.
    event EarningChainRemoved(uint256 chainId);

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

    /// @notice Adds an earning chain to the list of supported earning chains.
    /// @dev An Earning chain must be added to bridge funds to the chain and to obtain balances on the chain from an
    /// oracle. @param chainId Chain id of the earning chain to add.
    function addEarningChain(uint256 chainId) external;

    /// @notice Removes an earning chain from the list of supported earning chains.
    /// @dev An Earning chain must be removed to stop bridging funds to the chain and to stop obtaining balances on the
    /// chain from an oracle. @param chainId Chain id of the earning chain to remove.
    function removeEarningChain(uint256 chainId) external;

    /// @notice Forward a deposit to a liquidity source.
    /// @param asset Address of the asset to deposit.
    /// @param amount Amount of the asset to deposit.
    /// @return netDepositAmount Amount of the asset deposited.
    function processDeposit(address asset, uint256 amount) external returns (uint256);

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

    /// @notice Callback function for when funds arrive from a chain.
    /// @param asset Address of the asset that arrived from the chain.
    /// @param amount Amount of the asset that arrived from the chain.
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external;
}
