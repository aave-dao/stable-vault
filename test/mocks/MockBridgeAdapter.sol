// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";

contract MockBridgeAdapter is IBridgeAdapter {
    address internal immutable TRANSFER_HELPER;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    function getGateway() external view override returns (address) {}

    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        IBridgeAdapter.BridgeAsset[] memory assets,
        bytes memory data,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override {
        (destinationChainId, data);
        // pull assets from TH
        if (assets.length > 0) {
            for (uint256 i = 0; i < assets.length; i++) {
                ITransferHelper(TRANSFER_HELPER).pull(assets[i].asset, assets[i].amount);
            }
        }
        ITransferHelper(TRANSFER_HELPER).pull(bridgeParams.feeToken, bridgeParams.feeAmount);
    }

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override {}

    function replayFundsReceiving(IBridgeAdapter.BridgeAsset[] memory assets) external override {}

    receive() external payable {}
}
