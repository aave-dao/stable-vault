// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";
import {ICommunicationHandler} from "../interfaces/ICommunicationHandler.sol";
import {BaseCcipCommunicationAdapter} from "./BaseCcipCommunicationAdapter.sol";

contract AccountingCcipCommunicationAdapter is BaseCcipCommunicationAdapter {
    using SafeERC20 for IERC20;

    address _commHandler;

    function setCommunicationHandler(address communicationHandler) external {
        _commHandler = communicationHandler;
    }

    function pushFundsToChain(uint256 chainId, address asset, uint256 amount) external /* TODO: override */ {
        IERC20(asset).forceApprove(_ccipRouter, amount);
        Client.EVMTokenAmount[] memory allAssetsToPush = new Client.EVMTokenAmount[](1);
        allAssetsToPush[0] = Client.EVMTokenAmount({token: asset, amount: amount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiverOf[chainId]),
            data: "",
            tokenAmounts: allAssetsToPush,
            feeToken: _feeToken,
            // TODO: extra args contains dest chain gas limit which defaults to 200k
            extraArgs: ""
        });

        _sendMessage(chainId, message);
    }

    function pullFundsFromChain(uint256 chainId, uint256 amount) external /* TODO: override */ {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiverOf[chainId]),
            data: abi.encode(amount),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: _feeToken,
            extraArgs: ""
        });

        _sendMessage(chainId, message);
    }

    // TODO: expose admin function for destination chain replays of bridge data
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        // TODO: Verify it's coming from a proper sender on the other chain
        if (message.destTokenAmounts.length > 0) {
            _processFundsReceiving(message.sourceChainSelector, message.destTokenAmounts);
        }
        if (message.data.length > 0) {
            // We assume that if message.data is present then it must be a balance snapshot
            _processBalanceSnapshotReceiving(message.sourceChainSelector, abi.decode(message.data, (BalanceSnapshot)));
        }
    }

    function _processBalanceSnapshotReceiving(uint64 fromChainSelector, BalanceSnapshot memory balanceSnapshot)
        internal
    {
        // TODO: This call must not fail, we should catch if reverts
        ICommunicationHandler(_commHandler).receiveBalanceSnapshotMessage(
            _chainIdOf[fromChainSelector], balanceSnapshot.balance, balanceSnapshot.timestamp
        );
    }

    function _processFundsReceiving(uint64 fromChainSelector, Client.EVMTokenAmount[] memory assetsToReceive)
        internal
    {
        for (uint256 i = 0; i < assetsToReceive.length; i++) {
            address asset = assetsToReceive[i].token;
            uint256 amount = assetsToReceive[i].amount;
            IERC20(asset).forceApprove(_commHandler, amount);
            ICommunicationHandler(_commHandler).receiveFunds(_chainIdOf[fromChainSelector], asset, amount);
        }
    }
}
