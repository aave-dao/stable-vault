// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseBridgeAdapter} from "src/bridging/BaseBridgeAdapter.sol";
import {IAdiBridgeAdapter} from "src/interfaces/IAdiBridgeAdapter.sol";
import {IAdiCrossChainForwarder} from "src/interfaces/IAdiCrossChainForwarder.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title AdiAdapter
/// @author Aave Labs
/// @notice Adapter for sending and receiving data-only messages via a.DI.
contract AdiAdapter is BaseBridgeAdapter, IAdiBridgeAdapter {
    using SafeERC20 for IERC20;

    /// @notice Additional gas a.DI should allocate for this adapter before entering the destination Gateway.
    /// @dev The current mocked receiver trace measures the adapter wrapper at about 7,163 gas. Rounded up to 10k for
    /// calldata growth and cold access variance.
    uint256 public constant ADI_RECEIVER_GAS_OVERHEAD = 10_000;

    address internal immutable ADI_CROSS_CHAIN_CONTROLLER;

    modifier onlyCrossChainController() {
        require(msg.sender == ADI_CROSS_CHAIN_CONTROLLER, OnlyCrossChainController());
        _;
    }

    constructor(address accessManager, address gateway, address crossChainController, address transferHelper)
        BaseBridgeAdapter(accessManager, gateway, transferHelper)
    {
        require(crossChainController != address(0), Errors.ZeroAddress());
        ADI_CROSS_CHAIN_CONTROLLER = crossChainController;
    }

    /// @inheritdoc IAdiBridgeAdapter
    function getCrossChainController() external view override returns (address crossChainController) {
        return ADI_CROSS_CHAIN_CONTROLLER;
    }

    /// @inheritdoc IAdiBridgeAdapter
    function quoteMessageToChain(uint256 destinationChainId, bytes calldata messageData, uint256 gasLimit)
        external
        view
        override
        returns (uint256 nativeFee, IAdiCrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes)
    {
        address destinationChainAdapter = _destinationChainAdapterOf[destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());

        return _quoteForwardMessage(destinationChainId, destinationChainAdapter, gasLimit, messageData);
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory data,
        address feePayer,
        uint256 gasLimit,
        bytes memory bridgeAdapterData
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        require(asset == Constants.ASSET_FOR_DATA_ONLY_BRIDGE, Errors.UnsupportedAsset(asset));
        require(amount == 0, Errors.InvalidParameter());
        require(feePayer != address(0), Errors.ZeroAddress());
        require(bridgeAdapterData.length == 0, Errors.InvalidParameter());

        address destinationChainAdapter = _destinationChainAdapterOf[destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());

        uint256 adjustedGasLimit = gasLimit + ADI_RECEIVER_GAS_OVERHEAD;
        (uint256 nativeFee, IAdiCrossChainForwarder.Fee[] memory fees,) =
            _quoteForwardMessage(destinationChainId, destinationChainAdapter, gasLimit, data);
        _fundCrossChainController(feePayer, nativeFee, fees);

        (bytes32 envelopeId,) = IAdiCrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER)
            .forwardMessage(destinationChainId, destinationChainAdapter, adjustedGasLimit, data);
        emit MessagePublished(envelopeId);

        _refundExcessNative(feePayer, nativeFee);
    }

    /// @inheritdoc IAdiBridgeAdapter
    function receiveCrossChainMessage(
        address originSender,
        uint256 originChainId,
        bytes calldata message,
        bytes32 envelopeId
    ) external override onlyCrossChainController {
        address trustedOriginSender = _destinationChainAdapterOf[originChainId];
        require(trustedOriginSender != address(0), Errors.InvalidParameter());
        require(originSender == trustedOriginSender, OnlyDestinationChainAdapter());

        IChainGateway(GATEWAY).receiveMessage(originChainId, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, message);
        emit MessageReceived(envelopeId);
    }

    function _quoteForwardMessage(
        uint256 destinationChainId,
        address destinationChainAdapter,
        uint256 gasLimit,
        bytes memory data
    ) internal view returns (uint256 nativeFee, IAdiCrossChainForwarder.Fee[] memory fees, uint256 successfulQuotes) {
        IAdiCrossChainForwarder crossChainForwarder = IAdiCrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER);
        uint256 quoteBandwidth = crossChainForwarder.getOptimalBandwidthByChain(destinationChainId);
        return crossChainForwarder.quoteForwardMessage(
            destinationChainId, destinationChainAdapter, gasLimit + ADI_RECEIVER_GAS_OVERHEAD, data, quoteBandwidth
        );
    }

    function _fundCrossChainController(address feePayer, uint256 nativeFee, IAdiCrossChainForwarder.Fee[] memory fees)
        internal
    {
        require(msg.value >= nativeFee, Errors.InsufficientFunds());

        if (nativeFee > 0) {
            (bool callSucceeded,) = payable(ADI_CROSS_CHAIN_CONTROLLER).call{value: nativeFee}("");
            require(callSucceeded, Errors.NativeTransferFailed());
        }

        for (uint256 i = 0; i < fees.length; i++) {
            require(fees[i].token != address(0), Errors.InvalidParameter());
            require(fees[i].token != Constants.NATIVE_CURRENCY, Errors.InvalidParameter());
            if (fees[i].amount > 0) {
                IERC20(fees[i].token).safeTransferFrom(feePayer, ADI_CROSS_CHAIN_CONTROLLER, fees[i].amount);
            }
        }
    }

    function _refundExcessNative(address feePayer, uint256 nativeFee) internal {
        uint256 excessNative = msg.value - nativeFee;
        if (excessNative > 0) {
            (bool callSucceeded,) = payable(feePayer).call{value: excessNative}("");
            require(callSucceeded, Errors.NativeTransferFailed());
        }
    }
}
