// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {StableVault} from "src/core/accounting/StableVault.sol";

contract StableVaultHarness is StableVault {
    constructor(
        uint256 maxValidPerSecondRate,
        address assetRegistry,
        address iouTokenManager,
        address fundsHandler,
        address transferHelper,
        address withdrawalExecutionPolicy,
        address priceOracle,
        uint256 maxActiveSubVaults,
        address policyRegistry
    )
        StableVault(
            maxValidPerSecondRate,
            assetRegistry,
            iouTokenManager,
            fundsHandler,
            transferHelper,
            withdrawalExecutionPolicy,
            priceOracle,
            maxActiveSubVaults,
            policyRegistry
        )
    {}

    function moveSharesHarness(
        address from,
        address to,
        uint256 fromSubVaultId,
        uint256 toSubVaultId,
        uint256 sharesToBurn,
        uint256 sharesToMint,
        uint256 guaranteedAmountToMoveRay
    ) external {
        _moveShares(from, to, fromSubVaultId, toSubVaultId, sharesToBurn, sharesToMint, guaranteedAmountToMoveRay);
    }

    function previewFullWithdrawalSharesHarness(address user) external view returns (uint256) {
        (,, uint256 sharesToRedeem) = _previewFullWithdrawalRequest(user);
        return sharesToRedeem;
    }
}
