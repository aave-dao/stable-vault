// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IChainGateway} from "./IChainGateway.sol";

interface IAccountingChainGateway is IChainGateway {
    error NotFundsHandler();

    /// @notice Sends assets to an Earning Chain.
    /// @dev The Accounting Chain does not prescribe to the Earning Chain which strategy to push assets to.
    /// @dev One asset is pushed at a time to avoid depedencies on bridges that support multiple assets bridged
    /// together.
    /// @param asset The asset to send.
    /// @param amount The amount of the asset to send.
    /// @param targetChainId The chain id of the Earning Chain to send the assets to.
    /// @param bridgeAdapterParams The parameters for the bridge adapter.
    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        BridgeAdapterParams memory bridgeAdapterParams
    ) external payable;
}
