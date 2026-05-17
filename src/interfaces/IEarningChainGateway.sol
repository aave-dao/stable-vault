// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainGateway} from "src/interfaces/IChainGateway.sol";

/// @title IEarningChainGateway
/// @author Aave Labs
/// @notice Interface for gateway functionality required on the Earning Chain.
interface IEarningChainGateway is IChainGateway {
    /// @notice Emitted when assets are removed from the Earning Chain.
    /// @dev Can be emitted when IOUs are exchanged for assets or funds are returned to the Accounting Chain.
    /// @param asset The asset that was removed.
    /// @param amount The amount of the asset that was removed.
    event AssetOutflow(address indexed asset, uint256 amount);

    /// @notice The aggregated balance of the Earning Chain.
    function getAggregatedBalance() external view returns (uint256);

    /// @notice Withdraws a specific asset from the Allocator and bridges it to the Accounting Chain.
    /// @param asset The asset to withdraw.
    /// @param amount The amount of the asset to withdraw in the asset's native decimals.
    /// @param bridgeAdapter The whitelisted bridge adapter to use for bridging the asset.
    /// @param receiverExecutionGasLimit Gas limit for destination receiver execution, including adapter receive logic,
    /// token handling, gateway execution, and any non-empty arbitrary data processing. Excludes bridge provider
    /// operations before and after the receiver call.
    /// @param bridgeAdapterData Any bridge adapter custom parameters that it may need to operate.
    /// @param policyData Additional data that the bridge-funds policy might need to operate.
    function pushFundsToAccountingChain(
        address asset,
        uint256 amount,
        address bridgeAdapter,
        uint256 receiverExecutionGasLimit,
        bytes calldata bridgeAdapterData,
        bytes calldata policyData
    ) external payable;

    /// @notice Exchanges IOU tokens for a specific asset and bridges data back to the Accounting Chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to exchange.
    /// @param assetOut The asset to exchange the IOU tokens for.
    /// @param minAmountOut The minimum amount of `assetOut` to receive for `iouTokenAmountRay` of IOU tokens.
    /// @param receiver The address to send the exchanged asset to.
    /// @param bridgeAdapter The whitelisted bridge adapter to use for the data-only message.
    /// @param payloadExecutionGasLimit Gas limit for the destination gateway call and everything it executes.
    /// @param bridgeAdapterData Any bridge adapter custom parameters that it may need to operate.
    /// @param policyData Additional data that the withdrawal execution policy might need to operate.
    /// @return amountOut The amount of the exchanged asset transferred to the receiver.
    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address assetOut,
        uint256 minAmountOut,
        address receiver,
        address bridgeAdapter,
        uint256 payloadExecutionGasLimit,
        bytes calldata bridgeAdapterData,
        bytes memory policyData
    ) external payable returns (uint256);
}
