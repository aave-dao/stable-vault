// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IWithdrawalExecutionPolicy} from "src/interfaces/IWithdrawalExecutionPolicy.sol";

contract MockWithdrawalExecutionPolicy is IWithdrawalExecutionPolicy {
    /// @dev Returns the full iouAmountRay (no fee) for testing purposes.
    function applyWithdrawalExecutionPolicy(WithdrawalExecutionIntent calldata withdrawalExecution)
        external
        pure
        override
        returns (uint256)
    {
        return withdrawalExecution.iouAmountRay;
    }

    /// @dev Returns the full iouAmountRay (no fee) for testing purposes.
    function previewWithdrawalExecutionPolicy(WithdrawalExecutionIntent calldata withdrawalExecution)
        external
        pure
        override
        returns (uint256)
    {
        return withdrawalExecution.iouAmountRay;
    }
}
