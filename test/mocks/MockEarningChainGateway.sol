// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";

contract MockEarningChainGateway is IEarningChainGateway {
    address internal immutable TRANSFER_HELPER;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    function getIouTokenManager() external view returns (address) {}

    function getAggregatedBalance() external view returns (uint256) {}

    function sendBalanceUpdateWithFeePayer(bytes calldata bridgeParamsEncoded) external payable {}

    function pushFundsToAccountingChain(
        address asset,
        uint256 amount,
        address bridgeAdapter,
        bytes calldata bridgeParamsEncoded
    ) external payable {}

    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address assetOut,
        uint256 minAmountOut,
        address receiver,
        address bridgeAdapter,
        bytes calldata bridgeParamsEncoded,
        bytes memory data
    ) external payable returns (uint256) {}

    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        address bridgeAdapter,
        address feePayer,
        bytes calldata bridgeParamsEncoded
    ) external payable {}

    function addBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter) external {}

    function removeBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter) external {}

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
        address bridgeAdapter,
        address feePayer,
        bytes calldata bridgeParamsEncoded
    ) external payable {}
}
