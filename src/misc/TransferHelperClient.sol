// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title TransferHelperClient
/// @author Aave Labs
/// @notice Client for components that push assets into the TransferHelper or expect assets to be pushed into the
/// TransferHelper.
/// @dev This contract is used to assert that the TransferHelper has consumed the assets it is expected to consume.
abstract contract TransferHelperClient {
    using SafeERC20 for IERC20;

    error TransferHelperBalanceNotConsumed(address asset);

    address internal immutable TRANSFER_HELPER;

    /// @dev Constructor.
    /// @param transferHelper Address of the TransferHelper contract.
    constructor(address transferHelper) {
        ITransferHelper(transferHelper).getBalance(Constants.NATIVE_CURRENCY);
        TRANSFER_HELPER = transferHelper;
    }

    modifier assertingTransferHelperBalanceFor(address asset) {
        uint256 balanceBefore = _transferHelperBalance(asset);
        _;
        uint256 balanceAfter = _transferHelperBalance(asset);
        require(balanceAfter <= balanceBefore, TransferHelperBalanceNotConsumed(asset));
    }

    modifier assertingTransferHelperBalanceForAssets(address[] memory assets) {
        uint256[] memory balancesBefore = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            balancesBefore[i] = _transferHelperBalance(assets[i]);
        }
        _;
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 balanceAfter = _transferHelperBalance(assets[i]);
            require(balanceAfter <= balancesBefore[i], TransferHelperBalanceNotConsumed(assets[i]));
        }
    }

    function _transferHelperBalance(address asset) private view returns (uint256) {
        if (asset == Constants.NATIVE_CURRENCY) {
            return TRANSFER_HELPER.balance;
        }
        return IERC20(asset).balanceOf(TRANSFER_HELPER);
    }

    /// @dev Transfers the bridge fee to the TransferHelper to be pulled by Bridge Adapter.
    function _transferBridgeFeeToTransferHelper(IBridgeAdapter.BridgeParams memory bridgeParams) internal {
        require(bridgeParams.feePayer == msg.sender, Errors.InvalidBridgeFeePayer());
        if (msg.value > 0) {
            // If there is some msg.value, we transfer it to the TransferHelper, regardless of the fee token.
            // There might be scenarios where the bridge implementation requires some native assets to operate in
            // addition to the ERC-20 fee token.
            _transferNativeToTransferHelper(msg.value);
        }
        if (bridgeParams.feeToken == Constants.NATIVE_CURRENCY) {
            // We already transferred all the msg.value above. Here we just check that it covers the fee amount.
            require(msg.value >= bridgeParams.feeAmount, Errors.InsufficientFunds());
        } else if (bridgeParams.feeAmount > 0) {
            IERC20(bridgeParams.feeToken)
                .safeTransferFrom(bridgeParams.feePayer, TRANSFER_HELPER, bridgeParams.feeAmount);
        }
    }

    function _transferToTransferHelper(address asset, uint256 amount) internal {
        if (asset == Constants.NATIVE_CURRENCY) {
            _transferNativeToTransferHelper(amount);
        } else {
            IERC20(asset).safeTransfer(TRANSFER_HELPER, amount);
        }
    }

    /// @dev Does not support native currency, as it cannot be spent from another address. To transfer native currency,
    /// funds must be in this contract and the overloaded function without the `from` parameter should be used instead.
    function _transferToTransferHelper(address from, address asset, uint256 amount) internal {
        IERC20(asset).safeTransferFrom(from, TRANSFER_HELPER, amount);
    }

    function _transferNativeToTransferHelper(uint256 amount) private {
        (bool callSucceeded,) = TRANSFER_HELPER.call{value: amount}("");
        require(callSucceeded, Errors.NativeTransferFailed());
    }
}
