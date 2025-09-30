// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IVaultFundsHandler {
    function processWithdrawalRequest(
        address account,
        uint256 amount,
        uint256 originalDeposit,
        address preferredAsset,
        bytes calldata data
    ) external returns (uint256);

    function processDeposit(address account, address asset, uint256 amount) external;

    function processWithdrawal(uint256 withdrawalRequestId, bytes calldata data) external returns (bytes memory);
}
