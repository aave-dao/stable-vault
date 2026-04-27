// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BridgeParamsCodec} from "src/bridging/BridgeParamsCodec.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @dev Mirrors the opaque-bytes shape of IBridgeAdapter and the adapter-owned bridge-fee staging in
/// CcipAdapter: pulls feeToken directly from feePayer (or accepts native via msg.value) into itself,
/// then pulls the bridged amount from TransferHelper. The fee never enters the TransferHelper.
contract MockBridgeAdapter is IBridgeAdapter {
    using SafeERC20 for IERC20;

    address internal immutable TRANSFER_HELPER;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    function getGateway() external view override returns (address) {}

    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory data,
        address feePayer,
        bytes memory bridgeParamsEncoded
    ) external payable override {
        (destinationChainId, data);
        IBridgeAdapter.BridgeParams memory bridgeParams = BridgeParamsCodec.decode(bridgeParamsEncoded);

        // Mirror CcipAdapter: adapter pulls fee directly from feePayer (no TransferHelper round-trip).
        if (bridgeParams.feeToken == Constants.NATIVE_CURRENCY) {
            require(msg.value >= bridgeParams.feeAmount, Errors.InsufficientFunds());
        } else {
            require(msg.value == 0, Errors.InvalidParameter());
            if (bridgeParams.feeAmount > 0) {
                IERC20(bridgeParams.feeToken).safeTransferFrom(feePayer, address(this), bridgeParams.feeAmount);
            }
        }

        if (asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0) {
            ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
        }
    }

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override {}

    receive() external payable {}
}
