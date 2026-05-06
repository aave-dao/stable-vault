// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainGateway} from "src/interfaces/IChainGateway.sol";

/// @title IAccountingChainGateway
/// @author Aave Labs
/// @notice Interface for gateway functionality required on the Accounting Chain.
interface IAccountingChainGateway is IChainGateway {
    /// @notice Thrown when the caller is not the FundsHandler.
    /// @custom:selector 0x77607b1a
    error OnlyFundsHandler();

    /// @notice Thrown when the Earning Chain balance snapshot from the Chain Balance Oracle does not include the
    /// outbound cross-chain message block.
    /// @custom:selector 0xc6a06946
    error StaleChainBalance();

    /// @notice Sends assets to an Earning Chain.
    /// @dev The Accounting Chain does not prescribe to the Earning Chain which strategy to push assets to.
    /// @dev One asset is pushed at a time to avoid dependencies on bridges that support multiple assets bridged
    /// together.
    /// @param asset The asset to send.
    /// @param amount The amount of the asset to send.
    /// @param targetChainId The chain id of the Earning Chain to send the assets to.
    /// @param bridgeAdapter The whitelisted bridge adapter to use for bridging the asset.
    /// @param feePayer Address that will pay the bridge fee.
    /// @param gasLimit Gas limit that should be allocated for execution of the message on the destination chain,
    /// without considering the bridge adapter overhead.
    /// @param adapterData Adapter-specific data blob forwarded untouched to the adapter.
    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        address bridgeAdapter,
        address feePayer,
        uint256 gasLimit,
        bytes calldata adapterData
    ) external payable;
}
