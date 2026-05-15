// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @dev Mirrors the opaque-bytes shape of IBridgeAdapter and the adapter-owned bridge-fee staging in
/// CcipAdapter: pulls feeToken directly from feePayer (or accepts native via msg.value) into itself,
/// then pulls the bridged amount from TransferHelper. The fee never enters the TransferHelper.
contract MockBridgeAdapter is IBridgeAdapter {
    using SafeERC20 for IERC20;

    error PublishMessageFailed();

    address internal immutable TRANSFER_HELPER;
    bool internal _shouldRevertPublish;
    uint256 internal _feeAmount;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    function getGateway() external view override returns (address) {}

    function getDataOnlyReceiveGasOverhead() external pure override returns (uint256) {
        return 0;
    }

    function mockFeeAmount(uint256 feeAmount) external {
        _feeAmount = feeAmount;
    }

    function publishDataOnlyMessage(
        uint256 destinationChainId,
        bytes memory messageData,
        address feePayer,
        uint256 payloadExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) external payable override {
        _publishMessage(
            destinationChainId,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            messageData,
            feePayer,
            payloadExecutionGasLimit,
            bridgeAdapterData
        );
    }

    function publishMessageWithFunds(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory messageData,
        address feePayer,
        uint256 receiverExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) external payable override {
        require(asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0, Errors.InvalidParameter());
        _publishMessage(
            destinationChainId, asset, amount, messageData, feePayer, receiverExecutionGasLimit, bridgeAdapterData
        );
    }

    function _publishMessage(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory messageData,
        address feePayer,
        uint256 gasLimit,
        bytes memory bridgeAdapterData
    ) internal {
        require(!_shouldRevertPublish, PublishMessageFailed());

        (destinationChainId, messageData, gasLimit);
        ICcipBridgeAdapter.CcipFeeParams memory ccipFeeParams =
            abi.decode(bridgeAdapterData, (ICcipBridgeAdapter.CcipFeeParams));
        uint256 feeAmount = _feeAmount;

        // Mirror CcipAdapter: adapter pulls fee directly from feePayer (no TransferHelper round-trip).
        if (ccipFeeParams.feeToken == Constants.NATIVE_CURRENCY) {
            if (feeAmount == 0) {
                feeAmount = msg.value;
            }
            require(msg.value == feeAmount, Errors.InsufficientFunds());
        } else {
            require(msg.value == 0, Errors.InvalidParameter());
            if (feeAmount == 0) {
                feeAmount = IERC20(ccipFeeParams.feeToken).allowance(feePayer, address(this));
            }
            if (feeAmount > 0) {
                IERC20(ccipFeeParams.feeToken).safeTransferFrom(feePayer, address(this), feeAmount);
            }
        }

        if (asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0) {
            ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
        }
    }

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override {}

    function setShouldRevertPublish(bool shouldRevertPublish) external {
        _shouldRevertPublish = shouldRevertPublish;
    }

    receive() external payable {}
}
