// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";

contract MockBridgeAdapter is IBridgeAdapter {
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
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override {
        (destinationChainId, data);
        // pull assets from TH
        if (asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0) {
            ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
        }
        ITransferHelper(TRANSFER_HELPER).pull(bridgeParams.feeToken, bridgeParams.feeAmount);
    }

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override {}

    function replayFundsReceiving(IBridgeAdapter.BridgeAsset[] memory assets) external override {}

    receive() external payable {}
}
