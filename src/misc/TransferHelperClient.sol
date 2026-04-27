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
        uint256 assetsCount = assets.length;
        uint256[] memory balancesBefore = new uint256[](assetsCount);
        for (uint256 i = 0; i < assetsCount; i++) {
            balancesBefore[i] = _transferHelperBalance(assets[i]);
        }
        _;
        for (uint256 i = 0; i < assetsCount; i++) {
            uint256 balanceAfter = _transferHelperBalance(assets[i]);
            require(balanceAfter <= balancesBefore[i], TransferHelperBalanceNotConsumed(assets[i]));
        }
    }

    function _transferHelperBalance(address asset) internal view returns (uint256) {
        if (asset == Constants.NATIVE_CURRENCY) {
            return TRANSFER_HELPER.balance;
        }
        return IERC20(asset).balanceOf(TRANSFER_HELPER);
    }

    /// @dev Transfers the bridge fee to the TransferHelper to be pulled by Bridge Adapter.
    /// @dev The legacy `feePayer == msg.sender` check was removed when fee-staging moved from caller
    /// contracts (IouTokenManager / FundsHandler) into the adapter under the opaque-bytes dispatch shape.
    /// Under adapter-level staging, `msg.sender` is the Gateway, not the original user — the check would
    /// reject every legitimate flow. ERC20 approval semantics already provide the required protection:
    /// `safeTransferFrom(feePayer, ...)` reverts unless `feePayer` has approved this contract, so a forged
    /// `feePayer` in the decoded params cannot move tokens.
    function _transferBridgeFeeToTransferHelper(IBridgeAdapter.BridgeParams memory bridgeParams) internal {
        if (bridgeParams.feeToken == Constants.NATIVE_CURRENCY) {
            require(msg.value >= bridgeParams.feeAmount, Errors.InsufficientFunds());
            _transferNativeToTransferHelper(msg.value);
        } else {
            // Assumes bridges will not require both native and ERC-20 fees.
            // Rejecting msg.value prevents accidental native loss (which would otherwise remain in this client
            // contract).
            require(msg.value == 0, Errors.InvalidParameter());
            if (bridgeParams.feeAmount > 0) {
                IERC20(bridgeParams.feeToken)
                    .safeTransferFrom(bridgeParams.feePayer, TRANSFER_HELPER, bridgeParams.feeAmount);
            }
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
