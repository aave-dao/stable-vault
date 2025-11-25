// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {IChainGateway} from "./IChainGateway.sol";

interface IAccountingChainGateway is IChainGateway {
    /// @notice Thrown when the caller is not the FundsHandler.
    /// @custom:selector 0xdc7a7100
    error NotFundsHandler();

    /// @notice Sends assets to an Earning Chain.
    /// @dev The Accounting Chain does not prescribe to the Earning Chain which strategy to push assets to.
    /// @dev One asset is pushed at a time to avoid depedencies on bridges that support multiple assets bridged
    /// together.
    /// @param asset The asset to send.
    /// @param amount The amount of the asset to send.
    /// @param targetChainId The chain id of the Earning Chain to send the assets to.
    /// @param bridgeParams The parameters for the bridge adapter.
    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable;
}
