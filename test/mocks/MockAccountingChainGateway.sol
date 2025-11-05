// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccountingChainGateway} from "../../src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";

contract MockAccountingChainGateway is IAccountingChainGateway {
    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view returns (address) {}

    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) external payable {}

    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external {}

    function sendBridgeIouTokenMessageWithFeePayer(
        address feeRefundRecipient,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount,
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) external payable {}
}
