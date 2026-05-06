// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";

contract MockAccountingChainGateway is IAccountingChainGateway {
    address internal immutable TRANSFER_HELPER;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    function getIouTokenManager() external view returns (address) {}

    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        address bridgeAdapter,
        address feePayer,
        uint256 gasLimit,
        bytes calldata bridgeParamsEncoded
    ) external payable {
        IBridgeAdapter(bridgeAdapter).publishMessageWithFunds{value: msg.value}(
            targetChainId, asset, amount, "", feePayer, gasLimit, bridgeParamsEncoded
        );
    }

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
        uint256 gasLimit,
        bytes calldata bridgeParamsEncoded
    ) external payable {}
}
