// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAdiCrossChainForwarder} from "src/interfaces/IAdiCrossChainForwarder.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title IAdiBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the AdiAdapter contract.
interface IAdiBridgeAdapter is IBridgeAdapter {
    /// @notice Address checked is not the configured a.DI CrossChainController.
    /// @custom:selector 0xe632d197
    error OnlyCrossChainController();

    /// @notice Getter for the address of the a.DI CrossChainController.
    /// @return crossChainController Address of the a.DI CrossChainController.
    function getCrossChainController() external view returns (address crossChainController);

    /// @notice Quotes the funding required to publish a data-only message through a.DI.
    /// @param destinationChainId Chain id of the destination chain.
    /// @param messageData Message payload to bridge.
    /// @param gasLimit Gas limit requested for Gateway payload execution on the destination chain.
    /// @return nativeFee Native funding required by a.DI.
    /// @return fees ERC20 funding required by a.DI.
    function quoteMessageToChain(uint256 destinationChainId, bytes calldata messageData, uint256 gasLimit)
        external
        view
        returns (uint256 nativeFee, IAdiCrossChainForwarder.Fee[] memory fees);

    /// @notice Receives a confirmed a.DI message from the configured CrossChainController.
    /// @param originSender Sender address on the origin chain.
    /// @param originChainId Chain id where the message originated.
    /// @param message Message payload bridged by a.DI.
    /// @param envelopeId a.DI envelope id.
    function receiveCrossChainMessage(
        address originSender,
        uint256 originChainId,
        bytes calldata message,
        bytes32 envelopeId
    ) external;
}
