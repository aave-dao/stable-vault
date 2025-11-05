// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IChainGateway} from "./IChainGateway.sol";

interface IBridgeAdapter {
    /// @notice Emitted when the processing of bridged funds fails.
    event BridgedFundsProcessingFailed(uint256 sourceChainId, bytes message, bytes error);

    error NotBridgeRouter();

    struct BridgeAsset {
        address asset;
        uint256 amount;
    }

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external;

    function replayFundsReceiving(uint256 sourceChainId, BridgeAsset[] memory assets) external;

    /// @notice Sends an arbitrary message containing instructions or data updates to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param assets The assets to bridge.
    /// @param data The arbitrary data that would be decoded and handled by the destination chain.
    /// @param bridgeAdapterParams The parameters for the bridge adapter.
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data,
        IChainGateway.BridgeAdapterParams memory bridgeAdapterParams
    ) external payable;
}
