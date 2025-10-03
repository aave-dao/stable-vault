// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IVaultFundsHandler} from "./interfaces/IVaultFundsHandler.sol";
import {IWithdrawalPriorityQueue} from "./interfaces/IWithdrawalPriorityQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AssetLib} from "../libraries/AssetLib.sol";

// Consider making it a library instead
contract FundsHandler is IVaultFundsHandler {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    struct WithdrawalRequest {
        address user;
        uint256 amountRequested;
        uint256 amountGuaranteed;
        address preferredAsset;
        uint256 requestTimestamp;
        bytes data;
    }

    mapping(uint256 withdrawalRequestId => WithdrawalRequest) internal _withdrawalRequests;
    uint256 internal _lastWithdrawalRequestId;
    IWithdrawalPriorityQueue internal _queue;

    // TODO: onlyBBVault
    function processWithdrawalRequest(
        address user,
        uint256 amount,
        uint256 guaranteedAmount,
        address preferredAsset,
        bytes calldata /* data */
    ) external override returns (uint256) {
        uint256 withdrawalRequestId = ++_lastWithdrawalRequestId;
        _withdrawalRequests[withdrawalRequestId] =
            WithdrawalRequest(user, amount, guaranteedAmount, preferredAsset, block.timestamp, "");
        // TODO: Implement anything else if needed
        return withdrawalRequestId;
    }

    // TODO: onlyBBVault
    function processDeposit(address user, address asset, uint256 amount) external override {
        // TODO: Implement
    }

    // TODO: onlyBBVault, but permissionless in the BBVault
    function processWithdrawalExecution(uint256 withdrawalRequestId, bytes calldata /* data */ )
        external
        override
        returns (uint256, bytes memory)
    {
        _verifyIfRequestCanBeProcessed(withdrawalRequestId);
        uint256 amount = _executeWithdrawal(withdrawalRequestId);
        return (amount, "");
    }

    function _executeWithdrawal(uint256 withdrawalRequestId) internal returns (uint256) {
        address asset = _withdrawalRequests[withdrawalRequestId].preferredAsset;
        uint256 amount = _withdrawalRequests[withdrawalRequestId].amountRequested.rayToAssetDecimals(asset);
        address destination = _withdrawalRequests[withdrawalRequestId].user;
        delete _withdrawalRequests[withdrawalRequestId];
        IERC20(asset).safeTransfer(destination, amount);
        return amount;
    }

    function _verifyIfRequestCanBeProcessed(uint256 withdrawalRequestId) internal view {
        // TODO: Implement
        // require(IWithdrawalPriorityQueue(_queue).canBeExecuted(withdrawalRequestId));
    }
}
