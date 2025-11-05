// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../../src/interfaces/IChainGateway.sol";

contract MockBridgeAdapter is IBridgeAdapter {
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        IBridgeAdapter.BridgeAsset[] memory assets,
        bytes memory data,
        IChainGateway.BridgeAdapterParams memory bridgeAdapterParams
    ) external payable override {}
    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override {}
    function replayFundsReceiving(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets)
        external
        override
    {}
}
