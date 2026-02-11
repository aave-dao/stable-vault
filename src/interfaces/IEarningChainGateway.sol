// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";

interface IEarningChainGateway is IChainGateway {
    /// @notice Emitted when assets are removed from the Earning Chain.
    /// @dev Can be emitted when IOUs are exchanged for assets or funds are returned to the Accounting Chain.
    /// @param assetOut The asset that was removed.
    /// @param amountOut The amount of the asset that was removed.
    event AssetOutflow(address indexed assetOut, uint256 amountOut);

    /// @notice The aggregated balance of the Earning Chain.
    function getAggregatedBalance() external view returns (uint256);

    /// @notice Withdraws a specific asset from the Allocator and bridges it to the Accounting Chain.
    /// @param asset The asset to withdraw.
    /// @param amount The `amount` must be in RAY to be token agnostic.
    /// @param bridgeParams The parameters for the bridge adapter.
    function pushFundsToAccountingChain(address asset, uint256 amount, IBridgeAdapter.BridgeParams memory bridgeParams)
        external
        payable;

    /// @notice Exchanges IOU tokens for a specific asset and bridges data back to the Accounting Chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to exchange.
    /// @param assetOut The asset to exchange the IOU tokens for.
    /// @param minAmountOut The minimum amount of `assetOut` to receive for `iouTokenAmountRay` of IOU tokens.
    /// @param receiver The address to send the exchanged asset to.
    /// @param bridgeParams The parameters for the bridge adapter.
    /// @param data Additional data for the withdrawal fee calculation.
    /// @return amountOut The amount of the exchanged asset transferred to the tokenOutReceiver.
    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address assetOut,
        uint256 minAmountOut,
        address receiver,
        IBridgeAdapter.BridgeParams memory bridgeParams,
        bytes memory data
    ) external payable returns (uint256);
}
