// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";

contract MockBridgeAdapter is IBridgeAdapter {
    function publishMessageToChain(
        uint256 destinationChainId,
        IBridgeAdapter.BridgeAsset[] memory assets,
        bytes memory data
    ) external override {}
    function publishMessageToChainWithFeePayer(
        address feeRefundRecipient,
        address feeToken,
        uint256 feeAmount,
        uint256 destinationChainId,
        IBridgeAdapter.BridgeAsset[] memory assets,
        bytes memory data
    ) external payable override {}
}
