// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {BaseCcipCommunicationAdapter} from "./BaseCcipCommunicationAdapter.sol";

contract EarningCcipCommunicationAdapter is BaseCcipCommunicationAdapter {
    using SafeERC20 for IERC20;

    address _earningChainRouter;

    function setEarningChainRouter(address earningChainRouter) external {
        _earningChainRouter = earningChainRouter;
    }

    // TODO: expose admin function for destination chain replays of bridge data
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        // TODO: Verify it's coming from a proper sender on the other chain
        if (message.destTokenAmounts.length > 0) {
            _processFundsReceiving(message.sourceChainSelector, message.destTokenAmounts);
        }
        if (message.data.length > 0) {
            // We assume that if message.data is present then it must be a pull funds request
            _processPullFunds(message.sourceChainSelector, abi.decode(message.data, (uint256)));
        }
    }

    function sendFundsWithBalanceSnapshot(
        uint256 chainId,
        address asset,
        uint256 amount,
        uint256 balance,
        uint256 timestamp
    ) external {
        IERC20(asset).forceApprove(_ccipRouter, amount);
        Client.EVMTokenAmount[] memory allAssetsToPush = new Client.EVMTokenAmount[](1);
        allAssetsToPush[0] = Client.EVMTokenAmount({token: asset, amount: amount});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiverOf[chainId]),
            data: abi.encode(BalanceSnapshot(balance, timestamp)),
            tokenAmounts: allAssetsToPush,
            feeToken: _feeToken,
            // TODO: extra args contains dest chain gas limit which defaults to 200k
            extraArgs: ""
        });

        _sendMessage(chainId, message);
    }

    function _processPullFunds(uint64 fromChainSelector, uint256 amount) internal {
        revert("UNSUPPORTED");
        // TODO: re Emergency Withdrawal how to decide which token to pull from Allocator?
        // TODO: do we need to ccipSend multiple times to bridge multiple tokens?
        // TODO: Keep in mind not every asset in Earning chain will be bridgeable to Accounting chain
        // TODO: if someone emergencyWithdraws then have them wait a cooldown period since pull flow can fail if insufficient bridgeable assets are on Earning chain (assume no swap can be performed)
        // IEarningChainRouter(_earningChainRouter).pullFunds(fromChainSelector, amount);
    }

    function _processFundsReceiving(uint64 fromChainSelector, Client.EVMTokenAmount[] memory assetsToReceive)
        internal
    {
        for (uint256 i = 0; i < assetsToReceive.length; i++) {
            address asset = assetsToReceive[i].token;
            uint256 amount = assetsToReceive[i].amount;
            IERC20(asset).forceApprove(_earningChainRouter, amount);
            // IEarningChainRouter(_earningChainRouter).receiveFunds(_chainIdOf[fromChainSelector], asset, amount);
        }
    }
}
