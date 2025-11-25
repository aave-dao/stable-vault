// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IWithdrawalFeeCalculator {
    function calculateWithdrawalFee(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        returns (uint256);
}
