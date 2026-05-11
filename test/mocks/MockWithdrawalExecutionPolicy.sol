// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IWithdrawalExecutionPolicy} from "src/interfaces/IWithdrawalExecutionPolicy.sol";

contract MockWithdrawalExecutionPolicy is IWithdrawalExecutionPolicy {
    /// @dev Returns the full iouAmountRay (no fee) for testing purposes.
    function applyWithdrawalExecutionPolicy(WithdrawalExecutionPolicyRequest calldata request)
        external
        pure
        override
        returns (uint256)
    {
        return request.iouAmountRay;
    }

    /// @dev Returns the full iouAmountRay (no fee) for testing purposes.
    function previewWithdrawalExecutionPolicy(WithdrawalExecutionPolicyRequest calldata request)
        external
        pure
        override
        returns (uint256)
    {
        return request.iouAmountRay;
    }
}
