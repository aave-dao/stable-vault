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

    function processWithdrawalRequest(
        address recipient,
        uint256 amount,
        uint256 guaranteedAmount,
        address preferredAsset,
        bytes calldata data
    ) external returns (uint256);

    function processDeposit(address asset, uint256 amount) external;

    function processWithdrawalExecution(uint256 withdrawalRequestId, bytes calldata data)
        external
        returns (address, uint256, address, bytes memory);

    function pushFundsToChain(address asset, uint256 amount, uint256 chainId) external;

    function pullFundsFromChain(uint256 amount, uint256 chainId) external;

    /// @param chainId The chain id of the chain that sent the balance update
    /// @param balanceSnapshot The balance snapshot on the source chain in RAY of supported asset denomination
    /// @param snapshotTimestamp The timestamp of the balance snapshot from the source chain
    function updateChainBalanceCallback(uint256 chainId, uint256 balanceSnapshot, uint256 snapshotTimestamp) external;

    function fundsArrivedFromChainCallback(address asset, uint256 amount) external;

    function getAssetBalances() external returns (AssetBalance[] memory);

    /// @dev Returns the total liquidity across all supported chains in RAY of supported asset denomination.
    function getAggregatedBalance() external view returns (uint256);

    /// @dev Retrieve funds from liquidity source to make available to spend.
    function pullFromLiquidity(address asset, uint256 amount) external;

    function rescueTokens(address asset, uint256 amount) external;
}
