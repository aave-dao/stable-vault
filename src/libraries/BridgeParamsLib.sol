// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "./ErrorsLib.sol";

library BridgeParamsLib {
    using SafeERC20 for IERC20;

    address public constant BRIDGE_FEE_ON_NATIVE_CURRENCY = address(0);

    /// @dev Intended to be used by the entrypoint function on a contract that is approved as a spender for the bridge
    /// fee by the fee payer.
    function sendBridgeFeeToTransferHelper(IChainGateway.BridgeParams memory bridgeParams, address transferHelper)
        internal
    {
        if (msg.value > 0) {
            // If there is some msg.value, we transfer it to the TransferHelper, regardless of the fee token.
            // There might be scenarios where the bridge implementation requires some native assets to operate in
            // addition to the ERC-20 fee token.
            (bool callSucceeded,) = transferHelper.call{value: msg.value}("");
            require(callSucceeded, ErrorsLib.NativeTransferFailed());
        }
        if (bridgeParams.feeToken == BRIDGE_FEE_ON_NATIVE_CURRENCY) {
            // We already transferred all the msg.value above. Here we just check that it covers the fee amount.
            require(msg.value >= bridgeParams.feeAmount, ErrorsLib.InsufficientFunds());
        } else {
            IERC20(bridgeParams.feeToken)
                .safeTransferFrom(bridgeParams.feePayer, transferHelper, bridgeParams.feeAmount);
        }
    }
}
