// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BridgeParamsCodec} from "src/bridging/BridgeParamsCodec.sol";
import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

contract MockAccountingChainGateway is IAccountingChainGateway {
    using SafeERC20 for IERC20;

    address internal immutable TRANSFER_HELPER;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    address[] _assetsToPullFromTransferHelperInNextCall;
    uint256[] _amountsToPullFromTransferHelperInNextCall;

    function mockToConsumeAssetFromTransferHelperInNextCall(address asset, uint256 amount) external {
        _assetsToPullFromTransferHelperInNextCall.push(asset);
        _amountsToPullFromTransferHelperInNextCall.push(amount);
    }

    function getIouTokenManager() external view returns (address) {}

    /// @dev Simulates adapter-owned fee staging: decodes bridge params, pulls feeToken from feePayer
    /// (or accepts native via msg.value) into TransferHelper, then simulates asset+fee consumption.
    function sendPushFundsToChainMessage(
        address, // asset
        uint256, // amount
        uint256, // targetChainId
        address, // adapter
        bytes calldata bridgeParamsEncoded
    )
        external
        payable
    {
        _stageBridgeFee(bridgeParamsEncoded);
        _pullAssetsFromTransferHelper();
    }

    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    /// @dev Called by Bridge Adapters which use the TransferHelper modifiers that assert no funds left in the
    /// TransferHelper.
    function receiveMessage(uint256 sourceChainId, address asset, uint256 amount, bytes memory data) external {
        (sourceChainId, data);
        if (asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0) {
            ITransferHelper(TRANSFER_HELPER).transfer(asset, amount, address(this));
        }
    }

    function sendBridgeIouTokenMessageWithFeePayer(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        address adapter,
        bytes calldata bridgeParamsEncoded
    ) external payable {}

    function _stageBridgeFee(bytes calldata bridgeParamsEncoded) internal {
        IBridgeAdapter.BridgeParams memory bridgeParams = BridgeParamsCodec.decode(bridgeParamsEncoded);
        if (bridgeParams.feeToken == Constants.NATIVE_CURRENCY) {
            require(msg.value >= bridgeParams.feeAmount, Errors.InsufficientFunds());
            if (msg.value > 0) {
                (bool ok,) = TRANSFER_HELPER.call{value: msg.value}("");
                require(ok, Errors.NativeTransferFailed());
            }
        } else {
            require(msg.value == 0, Errors.InvalidParameter());
            if (bridgeParams.feeAmount > 0) {
                IERC20(bridgeParams.feeToken)
                    .safeTransferFrom(bridgeParams.feePayer, TRANSFER_HELPER, bridgeParams.feeAmount);
            }
        }
    }

    function _pullAssetsFromTransferHelper() internal {
        if (_assetsToPullFromTransferHelperInNextCall.length > 0) {
            ITransferHelper(TRANSFER_HELPER)
                .pull(_assetsToPullFromTransferHelperInNextCall, _amountsToPullFromTransferHelperInNextCall);
        }
    }
}
