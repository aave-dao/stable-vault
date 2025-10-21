// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IAssetRegistry {
    function isAllowedToDepositIntoBBV(address asset) external returns (bool);
    function isAllowedToWithdrawFromBBV(address asset) external returns (bool);
}
