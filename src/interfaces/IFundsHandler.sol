// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IFundsHandler {
    error OnlyBaseBoostedVault();
    error OnlyCommunicationHandler();

    struct AssetBalance {
        address asset;
        uint256 amountRay;
        uint256 chainId;
        uint256 timestamp;
    }

    function processWithdrawalRequest(
        address user,
        uint256 amount,
        uint256 guaranteedAmount,
        address preferredAsset,
        bytes calldata data
    ) external returns (uint256);

    function processDeposit(address user, address asset, uint256 amount) external;

    function processWithdrawalExecution(uint256 withdrawalRequestId, bytes calldata data)
        external
        returns (uint256, bytes memory);

    function pushFundsToChain(address asset, uint256 amount, uint256 chainId) external;

    function pullFundsFromChain(uint256 amount, uint256 chainId) external;

    /// @param chainId The chain id of the chain that sent the balance update
    /// @param balanceSnapshot The balance snapshot on the source chain in RAY of supported asset denomination
    /// @param snapshotTimestamp The timestamp of the balance snapshot from the source chain
    function updateChainBalanceCallback(uint256 chainId, uint256 balanceSnapshot, uint256 snapshotTimestamp) external;

    function fundsArrivedFromChainCallback(uint256 chainId, address asset, uint256 amount) external;

    function getAssetBalances() external returns (AssetBalance[] memory);
}
