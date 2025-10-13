// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";

contract CcipAdapter is IAdapter {
    // TODO: Immutable? and we release a new version if the router changes
    address _router;

    // TODO: Should we do one adapter per chain id with immutables?
    mapping(uint256 chainId => uint64 ccipChainSelector) _chainSelectorOf;

    mapping(uint256 chainId => address receiver) _receiverOf;

    // Client.EVMTokenAmount, Client.Any2EVMMessage, Client.EVM2AnyMessage
    function pushFundsToChain(uint256 chainId, address asset, uint256 amount) external override {
        uint64 chainSelector = _chainSelectorOf[chainId];

        Client.EVMTokenAmount memory assetsToPush = Client.EVMTokenAmount({token: asset, amount: amount});
        Client.EVMTokenAmount[] memory allAssetsToPush = new Client.EVMTokenAmount[](1);
        allAssetsToPush[0] = assetsToPush;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiverOf[chainId]),
            data: "",
            tokenAmounts: allAssetsToPush,
            feeToken: address(0), // TODO: Which one do we use? or we do native currency to simplify it?
            extraArgs: ""
        });

        IRouterClient(_router).ccipSend(chainSelector, message);
    }

    function pullFundsFromChain(uint256 amount) external override {}

    function sendMessage(uint256 targetChainId, bytes memory message) external override {}

    function sendFunds(uint256 targetChainId, address asset, uint256 amount, bytes memory message) external override {}

    function receiveBridgeMessage(uint256 fromChainId, bytes memory message) external override {}
}
