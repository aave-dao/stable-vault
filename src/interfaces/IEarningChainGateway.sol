// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IChainGateway} from "./IChainGateway.sol";

interface IEarningChainGateway is IChainGateway {
    /// @notice The ID of the Accounting Chain.
    function getAccountingChainId() external view returns (uint256);

    /// @notice The aggregated balance of the Earning Chain.
    function getAggregatedBalance() external view returns (uint256);

    /// @notice Sends a balance update to the Accounting Chain.
    function sendBalanceUpdate() external;

    /// @notice Sends a balance update to the Accounting Chain with bridging fees taken by specified payer.
    /// @param bridgeFeePayer The address that will pay the bridge fee (this receives a refund if funds from
    /// bridgeFeeAmount are not used).
    /// @param bridgeFeeToken The token to pay the bridge fee in.
    /// @param bridgeFeeAmount The estimated amount of fee to pay in the fee token.
    function sendBalanceUpdateWithFeePayer(address bridgeFeePayer, address bridgeFeeToken, uint256 bridgeFeeAmount)
        external
        payable;

    /// @notice Withdraws a specific asset from the Allocator and bridges it to the Accounting Chain.
    /// @param asset The asset to withdraw.
    /// @param amount The `amount` must be in RAY to be token agnostic.
    function exit(address asset, uint256 amount) external;

    /// @notice Exchanges IOU tokens for a specific asset and bridges data back to the Accounting Chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to exchange.
    /// @param tokenOut The asset to exchange the IOU tokens for.
    /// @param tokenOutReceiver The address to send the exchanged asset to.
    /// @param bridgeFeePayer The address that will pay the bridge fee (this receives a refund if funds from
    /// bridgeFeeAmount are not used).
    /// @param bridgeFeeToken The token to pay the bridge fee in.
    /// @param bridgeFeeAmount The amount of fee to pay in the fee token.
    /// @return amountOut The amount of the exchanged asset transferred to the tokenOutReceiver.
    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address tokenOut,
        address tokenOutReceiver,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) external payable returns (uint256);
}
