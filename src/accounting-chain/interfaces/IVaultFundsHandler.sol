// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IVaultFundsHandler {
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
}
