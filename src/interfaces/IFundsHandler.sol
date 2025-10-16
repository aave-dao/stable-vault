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

    struct WithdrawalRequest {
        address recipient;
        uint256 amountRequestedRay;
        uint256 amountGuaranteedRay;
        address preferredAsset;
        uint256 requestTimestamp;
        bytes data;
    }

    /// @dev Returns the total liquidity across all supported chains in RAY of supported asset denomination.
    function getAggregatedBalance() external view returns (uint256);

    /// @dev Returns the asset balances for all supported chains including the native chain.
    function getAssetBalances() external view returns (AssetBalance[] memory);

    /// @dev Returns the withdrawal request for a given withdrawal request id.
    /// @param withdrawalRequestId The id of the withdrawal request.
    function getWithdrawalRequest(uint256 withdrawalRequestId) external view returns (WithdrawalRequest memory);

    /// @dev Forward a deposit to a liquidity source.
    /// @param asset The asset to deposit.
    /// @param amount The amount of the asset to deposit.
    function processDeposit(address asset, uint256 amount) external;

    /// @dev Initializes a withdrawal request by creating a withdrawal request id and updating storage.
    /// @param recipient The recipient of the withdrawal.
    /// @param amountRay The amount of the asset in RAY (token agnostic) to withdraw.
    /// @param guaranteedAmountRay Portion of the original deposit made by the recipient that is guaranteed to be
    /// withdrawable.
    /// @param preferredAsset Preferred asset to be transferred to the recipient.
    /// @param data Arbitrary data to pass to the withdrawal execution.
    function processWithdrawalRequest(
        address recipient,
        uint256 amountRay,
        uint256 guaranteedAmountRay,
        address preferredAsset,
        bytes calldata data
    ) external returns (uint256);

    /// @dev Executes a withdrawal request by pulling funds from the liquidity source and allowing them to be returned
    /// to the recipient.
    /// @param withdrawalRequestId The id of the withdrawal request as is stored.
    /// @param data Arbitrary data to pass to the withdrawal execution.
    function processWithdrawalExecution(uint256 withdrawalRequestId, bytes calldata data)
        external
        returns (address, uint256, address, bytes memory);

    /// @dev Retrieves funds from liquidity source on native chain beofre pushing funds to another chain throught the
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
