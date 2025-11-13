// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {IEarningChainGateway} from "../../src/interfaces/IEarningChainGateway.sol";
import {ITransferHelper} from "../../src/interfaces/ITransferHelper.sol";

contract MockEarningChainGateway is IEarningChainGateway {
    address internal immutable TRANSFER_HELPER;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    function getAggregatedBalance() external view returns (uint256) {}

    function sendBalanceUpdateWithFeePayer(BridgeParams memory bridgeParams) external payable {}

    function pushFundsToAccountingChain(address asset, uint256 amount, BridgeParams memory bridgeParams)
        external
        payable {}

    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address tokenOut,
        address tokenOutReceiver,
        BridgeParams memory bridgeParams
    ) external payable returns (uint256) {}

    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view returns (address) {}

    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        BridgeParams memory bridgeParams
    ) external payable {}

    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    /// @dev Called by Bridge Adapters which use the TransferHelper modifiers that assert no funds left in the
    /// TransferHelper.
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external
    {
        (sourceChainId, data);
        for (uint256 i = 0; i < assets.length; i++) {
            ITransferHelper(TRANSFER_HELPER).transfer(assets[i].asset, assets[i].amount, address(this));
        }
    }

    function sendBridgeIouTokenMessageWithFeePayer(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        BridgeParams memory bridgeParams
    ) external payable {}
}
