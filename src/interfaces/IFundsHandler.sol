// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IChainGateway} from "./IChainGateway.sol";

interface IFundsHandler {
    error NotBasedBoostedVault();
    error NotGateway();

    struct AssetBalance {
        address asset;
        uint256 amountRay;
        uint256 chainId;
    }

    /// @dev Returns the total liquidity across all supported chains in RAY of supported asset denomination.
    function getAggregatedBalance() external view returns (uint256);

    /// @dev Returns the asset balances for all supported chains including the native chain.
    function getAssetBalances() external view returns (AssetBalance[] memory);

    /// @dev Forward a deposit to a liquidity source.
    /// @param asset The asset to deposit.
    /// @param amount The amount of the asset to deposit.
    function processDeposit(address asset, uint256 amount) external;

    /// @dev Executes a withdrawal request by pulling funds from the liquidity source and allowing them to be returned
    /// to the recipient with the data passed to the request.
    /// @param asset the token to pull from liquidity sources
    /// @param amount the value of asset in decimals of the asset
    function processWithdrawal(address asset, uint256 amount) external;

    /// @dev Retrieves funds from liquidity source on native chain before pushing funds to another chain through the
    /// Gateway contract.
    /// @param asset The asset to push to the Accounting Chain.
    /// @param amount The amount of the asset to push to the Accounting Chain.
    /// @param chainId The chain id of the Accounting Chain.
    /// @param bridgeParams The parameters for the bridge adapter.
    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        IChainGateway.BridgeParams memory bridgeParams
    ) external payable;

    /// @dev Updates the chain balance snapshot for a given chain.
    /// @param chainId The chain id of the chain that sent the balance update
    /// @param snapshotBalanceRay The balance snapshot on the source chain in RAY of supported asset denomination
    /// @param chainBalanceSnapshotNonce The nonce of the balance snapshot from the source chain.
    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 chainBalanceSnapshotNonce)
        external;

    function fundsArrivedFromChainCallback(address asset, uint256 amount) external;
}
