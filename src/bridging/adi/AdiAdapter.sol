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

        address destinationChainAdapter = _destinationChainAdapterOf[destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());

        _fundCrossChainController(feePayer, bridgeAdapterData);

        (bytes32 envelopeId,) = IAdiCrossChainForwarder(ADI_CROSS_CHAIN_CONTROLLER)
            .forwardMessage(destinationChainId, destinationChainAdapter, gasLimit, data);
        emit MessagePublished(envelopeId);
    }

    /// @inheritdoc IAdiBridgeAdapter
    function receiveCrossChainMessage(address originSender, uint256 originChainId, bytes calldata message)
        external
        override
        onlyCrossChainController
    {
        address trustedOriginSender = _destinationChainAdapterOf[originChainId];
        require(trustedOriginSender != address(0), Errors.InvalidParameter());
        require(originSender == trustedOriginSender, OnlyDestinationChainAdapter());

        IChainGateway(GATEWAY).receiveMessage(originChainId, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, message);
    }

    function _fundCrossChainController(address feePayer, bytes memory bridgeAdapterData) internal {
        if (msg.value > 0) {
            (bool callSucceeded,) = payable(ADI_CROSS_CHAIN_CONTROLLER).call{value: msg.value}("");
            require(callSucceeded, Errors.NativeTransferFailed());
        }

        if (bridgeAdapterData.length == 0) {
            return;
        }

        IAdiBridgeAdapter.Fee[] memory fees = abi.decode(bridgeAdapterData, (IAdiBridgeAdapter.Fee[]));
        for (uint256 i = 0; i < fees.length; i++) {
            require(fees[i].asset != address(0), Errors.InvalidParameter());
            require(fees[i].asset != Constants.NATIVE_CURRENCY, Errors.InvalidParameter());
            require(fees[i].amount > 0, Errors.InvalidParameter());
            IERC20(fees[i].asset).safeTransferFrom(feePayer, ADI_CROSS_CHAIN_CONTROLLER, fees[i].amount);
        }
    }
}
