// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IWithdrawalPolicy
/// @author Aave Labs
/// @notice Interface for the WithdrawalPolicy contract.
interface IWithdrawalPolicy {
    /// @notice Evaluates a withdrawal and calculates the withdrawal fee.
    /// @dev Checks the withdrawal against policies and reverts if any policy is violated.
    /// @param user Address of the user withdrawing the IOU tokens.
    /// @param assetOut Address of the asset to withdraw the IOU tokens to.
    /// @param iouAmountRay Amount of IOU tokens to withdraw.
    /// @param data Custom data required by the withdrawal policy.
    /// @return withdrawalFeeRay Amount of IOU tokens to be paid as a withdrawal fee.
    /// @return withdrawalFeeBps Withdrawal fee in basis points used to calculate the withdrawal fee.
    function evaluateWithdrawal(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        returns (uint256, uint16);
}
