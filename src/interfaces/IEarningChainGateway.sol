// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "./IBridgeAdapter.sol";
import {IChainGateway} from "./IChainGateway.sol";

interface IEarningChainGateway is IChainGateway {
    /// @notice The aggregated balance of the Earning Chain.
    function getAggregatedBalance() external view returns (uint256);

    /// @notice Sends a balance update to the Accounting Chain with bridging fees taken by specified payer.
    /// @param bridgeParams The parameters for the bridge adapter.
    function sendBalanceUpdateWithFeePayer(IBridgeAdapter.BridgeParams memory bridgeParams) external payable;

    /// @notice Withdraws a specific asset from the Allocator and bridges it to the Accounting Chain.
    /// @param asset The asset to withdraw.
    /// @param amount The `amount` must be in RAY to be token agnostic.
    /// @param bridgeParams The parameters for the bridge adapter.
    function pushFundsToAccountingChain(address asset, uint256 amount, IBridgeAdapter.BridgeParams memory bridgeParams)
        external
        payable;

    /// @notice Exchanges IOU tokens for a specific asset and bridges data back to the Accounting Chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to exchange.
    /// @param tokenOut The asset to exchange the IOU tokens for.
    /// @param tokenOutReceiver The address to send the exchanged asset to.
    /// @param bridgeParams The parameters for the bridge adapter.
    /// @return amountOut The amount of the exchanged asset transferred to the tokenOutReceiver.
    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address tokenOut,
        address tokenOutReceiver,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable returns (uint256);
}
