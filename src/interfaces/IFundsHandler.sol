// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IFundsHandler
/// @author Aave Labs
/// @notice Interface for the FundsHandler contract.
interface IFundsHandler {
    /// @notice Emitted when an earning chain is added.
    /// @param chainId Chain ID of the earning chain that was added.
    event EarningChainAdded(uint256 chainId);

    /// @notice Emitted when an earning chain is removed.
    /// @param chainId Chain ID of the earning chain that was removed.
    event EarningChainRemoved(uint256 chainId);

    /// @notice Thrown when the chain ID is already present in the Earning chain set.
    /// @custom:selector 0xff514c10
    error ChainIdAlreadyPresent();

    /// @notice Thrown when the chain ID can not be removed because it is not present in the Earning chain set.
    /// @custom:selector 0x20be9c4b
    error ChainIdNotPresent();

    /// @notice Thrown when the caller is not the StableVault.
    /// @custom:selector 0x53dad68c
    error OnlyStableVault();

    /// @notice Adds an earning chain to the list of supported earning chains.
    /// @dev An Earning chain must be added to bridge funds to the chain and to obtain balances on the chain from an
    /// oracle. Reverts if the ChainBalanceOracle does not yet support the chain, since a registered chain that the
    /// oracle does not support would make getAggregatedBalance() revert instead of treating the chain as stale.
    /// @param chainId Chain ID of the earning chain to add.
    function addEarningChain(uint256 chainId) external;

    /// @notice Removes an earning chain from the list of supported earning chains.
    /// @dev An Earning chain must be removed to stop bridging funds to the chain and to stop obtaining balances on the
    /// chain from an oracle.
    /// @param chainId Chain ID of the earning chain to remove.
    function removeEarningChain(uint256 chainId) external;

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
    /// @param asset Address of the asset to push to the destination chain.
    /// @param amount Amount of the asset to push to the destination chain.
    /// @param chainId Chain ID of the destination chain.
    /// @param bridgeAdapter The whitelisted bridge adapter to use for bridging the asset.
    /// @param receiverExecutionGasLimit Gas limit for destination receiver execution, including adapter receive logic,
    /// token handling, and gateway execution. Excludes bridge provider operations before and after the receiver call.
    /// @param bridgeAdapterData Any bridge adapter custom parameters that it may need to operate.
    /// @param policyData Additional data that the bridge-funds policy might need to operate.
    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        address bridgeAdapter,
        uint256 receiverExecutionGasLimit,
        bytes calldata bridgeAdapterData,
        bytes calldata policyData
    ) external payable;

    /// @notice Callback function for when funds arrive from a chain.
    /// @param asset Address of the asset that arrived from the chain.
    /// @param amount Amount of the asset that arrived from the chain.
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external;

    /// @notice Getter for the total assets in the local Allocator and the Allocators on all Earning Chains.
    /// @dev May underestimate when trust or freshness guarantees cannot be satisfied for a given contribution
    /// (conservative by design). See the implementation for specific policies.
    /// @return aggregatedBalance Total liquidity across all supported chains in RAY of the denominating currency.
    function getAggregatedBalance() external view returns (uint256);
}
