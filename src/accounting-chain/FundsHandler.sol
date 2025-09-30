// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IVaultFundsHandler} from "./interfaces/IVaultFundsHandler.sol";
import {IWithdrawalPriorityQueue} from "./interfaces/IWithdrawalPriorityQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FundsHandler is IVaultFundsHandler {
    using SafeERC20 for IERC20;

    struct WithdrawalRequest {
        address account;
        uint256 amountRequested;
        uint256 amountGuaranteed;
        address preferredAsset;
        uint256 requestTimestamp;
        bytes data;
    }

    mapping(uint256 withdrawalRequestId => WithdrawalRequest) internal _withdrawalRequests;
    uint256 internal _lastWithdrawalRequestId;
    IWithdrawalPriorityQueue internal _queue;

    function processWithdrawalRequest(
        address account,
        uint256 amount,
        uint256 originalDeposit,
        address preferredAsset,
        bytes calldata /* data */
    ) external override returns (uint256) {
        _lastWithdrawalRequestId++;
        _withdrawalRequests[_lastWithdrawalRequestId] =
            WithdrawalRequest(account, amount, originalDeposit, preferredAsset, block.timestamp, "");
        return _lastWithdrawalRequestId;
        // TODO: Implement
    }

    function processDeposit(address account, address asset, uint256 amount) external override {
        // TODO: Implement
    }

    function processWithdrawal(uint256 withdrawalRequestId, bytes calldata /* data */ )
        external
        override
        returns (bytes memory)
    {
        _verifyIfRequestCanBeProcessed(withdrawalRequestId);
        uint256 amount = _processActualWithdrawal(withdrawalRequestId);
        return abi.encode(amount);
    }

    function _processActualWithdrawal(uint256 withdrawalRequestId) internal returns (uint256) {
        address token = _withdrawalRequests[withdrawalRequestId].preferredAsset;
        uint256 amount = _withdrawalRequests[withdrawalRequestId].amountRequested;
        address destination = _withdrawalRequests[withdrawalRequestId].account;
        delete _withdrawalRequests[withdrawalRequestId];
        IERC20(token).transferFrom(address(this), destination, amount);
        return amount; // TODO: This might not be needed
    }

    function _verifyIfRequestCanBeProcessed(uint256 withdrawalRequestId) internal view {
        require(IWithdrawalPriorityQueue(_queue).canBeExecuted(withdrawalRequestId));
        // TODO: Implement
    }
}
