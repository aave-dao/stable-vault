// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {BasedBoostedVault} from "src/core/accounting/BasedBoostedVault.sol";

contract BasedBoostedVaultHarness is BasedBoostedVault {
    constructor(
        uint256 maxValidPerSecondRate,
        address assetRegistry,
        address iouTokenManager,
        address fundsHandler,
        address transferHelper,
        address withdrawalPolicy,
        uint256 maxActiveSubVaults
    )
        BasedBoostedVault(
            maxValidPerSecondRate,
            assetRegistry,
            iouTokenManager,
            fundsHandler,
            transferHelper,
            withdrawalPolicy,
            maxActiveSubVaults
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
