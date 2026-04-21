// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Constants} from "src/types/Constants.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract MockTransferHelperClient is TransferHelperClient {
    constructor(address transferHelper_) TransferHelperClient(transferHelper_) {}

    function exerciseSingleAsset(address asset) external assertingTransferHelperBalanceFor(asset) {}

    function exerciseMultiAsset(address[] memory assets) external assertingTransferHelperBalanceForAssets(assets) {}

    function consumeSingleAsset(address asset, uint256 amount) external assertingTransferHelperBalanceFor(asset) {
        _decreaseTransferHelperBalance(asset, amount);
    }

    function consumeMultiAsset(address[] memory assets, uint256[] memory amounts)
        external
        assertingTransferHelperBalanceForAssets(assets)
    {
        for (uint256 i = 0; i < assets.length; i++) {
            _decreaseTransferHelperBalance(assets[i], amounts[i]);
        }
    }

    function increaseSingleAsset(address asset, uint256 amount) external assertingTransferHelperBalanceFor(asset) {
        _increaseTransferHelperBalance(asset, amount);
    }

    function increaseMultiAsset(address[] memory assets, uint256[] memory amounts)
        external
        assertingTransferHelperBalanceForAssets(assets)
    {
        for (uint256 i = 0; i < assets.length; i++) {
            _increaseTransferHelperBalance(assets[i], amounts[i]);
        }
    }

    function transferHelper() external view returns (address) {
        return TRANSFER_HELPER;
    }

    function _decreaseTransferHelperBalance(address asset, uint256 amount) private {
        if (amount == 0) {
            return;
        }
        if (asset == Constants.NATIVE_CURRENCY) {
            MockTransferHelper(payable(TRANSFER_HELPER))
                .mockNativeOutboundToReachBalanceOf(TRANSFER_HELPER.balance - amount);
        } else {
            MockTransferHelper(payable(TRANSFER_HELPER))
                .mockAssetBalance(asset, _erc20Balance(asset, TRANSFER_HELPER) - amount);
        }
    }

    function _increaseTransferHelperBalance(address asset, uint256 amount) private {
        if (amount == 0) {
            return;
        }
        if (asset == Constants.NATIVE_CURRENCY) {
            // Send native currency from this contract's own balance (pre-funded by the test) to the helper.
            (bool ok,) = TRANSFER_HELPER.call{value: amount}("");
            require(ok, "native push failed");
        } else {
            MockTransferHelper(payable(TRANSFER_HELPER)).mockAsset(asset, amount);
        }
    }

    function _erc20Balance(address asset, address who) private view returns (uint256) {
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(data, (uint256));
    }

    receive() external payable {}
}
