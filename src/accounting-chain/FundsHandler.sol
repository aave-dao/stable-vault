// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IVaultFundsHandler} from "./interfaces/IVaultFundsHandler.sol";
import {IWithdrawalPriorityQueue} from "./interfaces/IWithdrawalPriorityQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Consider making it a library instead
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

    // TODO: onlyBBVault
    function processWithdrawalRequest(
        address account,
        uint256 amount,
        uint256 guaranteedAmount,
        address preferredAsset,
        bytes calldata /* data */
    ) external override returns (uint256) {
        uint256 withdrawalRequestId = ++_lastWithdrawalRequestId;
        _withdrawalRequests[withdrawalRequestId] =
            WithdrawalRequest(account, amount, guaranteedAmount, preferredAsset, block.timestamp, "");
        // TODO: Implement anything else if needed
        return withdrawalRequestId;
    }

    // TODO: onlyBBVault
    function processDeposit(address account, address asset, uint256 amount) external override {
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
        address token = _withdrawalRequests[withdrawalRequestId].preferredAsset;
        uint256 amount = _convertFromRayToAsset(token, _withdrawalRequests[withdrawalRequestId].amountRequested);
        address destination = _withdrawalRequests[withdrawalRequestId].account;
        delete _withdrawalRequests[withdrawalRequestId];
        IERC20(token).safeTransfer(destination, amount);
        return amount;
    }

    function _verifyIfRequestCanBeProcessed(uint256 withdrawalRequestId) internal view {
        // TODO: Implement
        // require(IWithdrawalPriorityQueue(_queue).canBeExecuted(withdrawalRequestId));
    }

    // TODO: Move this to some lib:
    function _convertFromAssetToRay(address asset, uint256 amount) internal view returns (uint256) {
        return _convertDecimals(asset, amount, _tryGetAssetDecimals(asset), 27);
    }

    function _convertFromRayToAsset(address asset, uint256 amount) internal view returns (uint256) {
        return _convertDecimals(asset, amount, 27, _tryGetAssetDecimals(asset));
    }

    function _convertDecimals(address, /* asset */ uint256 inputAmount, uint256 inputDecimals, uint256 outputDecimals)
        internal
        pure
        returns (uint256)
    {
        // TODO: improve this:
        if (inputDecimals == outputDecimals) return inputAmount;
        if (inputDecimals < outputDecimals) {
            uint256 multiplier = 10 ** (outputDecimals - inputDecimals);
            return inputAmount * multiplier;
        } else {
            uint256 divisor = 10 ** (inputDecimals - outputDecimals);
            return inputAmount / divisor;
        }
    }

    function _tryGetAssetDecimals(address asset) private view returns (uint8 assetDecimals) {
        // TODO: Make it try getting decimals and default to 18 if fails like OZ does
        return IERC20Metadata(asset).decimals();
    }
}
