// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IFundsHandler {
    error NotBaseBoostedVault();
    error NotGateway();

    struct AssetBalance {
        address asset;
        uint256 amountRay;
        uint256 chainId;
        uint256 timestamp;
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
    function pushFundsToChain(address asset, uint256 amount, uint256 chainId) external;

    /// @dev Uses the Gateway contract to request funds from another chain.
    /// @param amountRay The amount of the asset in RAY (token agnostic) to pull from the chain.
    /// @param chainId The chain id of the chain to request funds from.
    function pullFundsFromChain(uint256 amountRay, uint256 chainId) external;

    /// @dev Updates the chain balance snapshot for a given chain.
    /// @param chainId The chain id of the chain that sent the balance update
    /// @param snapshotBalanceRay The balance snapshot on the source chain in RAY of supported asset denomination
    /// @param snapshotTimestamp The timestamp of the balance snapshot from the source chain
    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 snapshotTimestamp) external;

    function fundsArrivedFromChainCallback(address asset, uint256 amount) external;

    /// @dev Retrieve funds from liquidity source to make available to spend.
    function pullFromLiquidity(address asset, uint256 amount) external;

    /// @dev Rescue tokens stuck on the contract.
    /// @param asset The asset to rescue.
    /// @param amount The amount of the asset to rescue.
    function rescueTokens(address asset, uint256 amount) external;
}
