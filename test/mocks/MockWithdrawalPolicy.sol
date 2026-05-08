// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {IWithdrawalRequestPolicy} from "src/interfaces/IWithdrawalRequestPolicy.sol";

contract MockWithdrawalPolicy is IWithdrawalPolicy, IWithdrawalRequestPolicy {
    /// @dev Returns the full iouAmountRay (no fee) for testing purposes.
    function applyWithdrawalPolicy(WithdrawalRequest calldata request) external pure override returns (uint256) {
        return request.iouAmountRay;
    }

    /// @dev Returns the full iouAmountRay (no fee) for testing purposes.
    function previewWithdrawalPolicy(WithdrawalRequest calldata request) external pure override returns (uint256) {
        return request.iouAmountRay;
    }

    function applyWithdrawalRequestPolicy(WithdrawalRequestPolicyRequest calldata)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    function previewWithdrawalRequestPolicy(WithdrawalRequestPolicyRequest calldata)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }
}
