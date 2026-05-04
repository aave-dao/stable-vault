// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title IAdiBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the AdiAdapter contract.
interface IAdiBridgeAdapter is IBridgeAdapter {
    /// @notice ERC20 funding to transfer from `feePayer` to the a.DI CrossChainController.
    /// @param asset ERC20 asset to fund with.
    /// @param amount Amount to transfer.
    /// @dev The array of Fee[] should be abi.encoded as bridgeAdapterData in publishMessageToChainWithFeePayer.
    /// @dev If no ERC20 fees are required, the bridgeAdapterData can be empty bytes.
    struct Fee {
        address asset;
        uint256 amount;
    }

    /// @notice Address checked is not the configured a.DI CrossChainController.
    /// @custom:selector 0xe632d197
    error OnlyCrossChainController();

    /// @notice Getter for the address of the a.DI CrossChainController.
    /// @return crossChainController Address of the a.DI CrossChainController.
    function getCrossChainController() external view returns (address crossChainController);

    /// @notice Receives a confirmed a.DI message from the configured CrossChainController.
    /// @param originSender Sender address on the origin chain.
    /// @param originChainId Chain id where the message originated.
    /// @param message Message payload bridged by a.DI.
    function receiveCrossChainMessage(address originSender, uint256 originChainId, bytes calldata message) external;
}
