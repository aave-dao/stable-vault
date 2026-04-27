// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {EarningChainBaseScript} from "script/interact/earning/EarningChainBaseScript.s.sol";

import {BridgeParamsCodec} from "src/bridging/BridgeParamsCodec.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";

/// @dev See example usage below:
/// 1. > export RPC_URL=<rpc-url>
/// 2. > cast wallet import <account_name> --private-key 0xYOUR_PRIVATE_KEY
/// 3. > forge script script/interact/earning/EarningChainGatewayInteractionScript.s.sol \
///  --rpc-url $RPC_URL \
///  --sig "sendBalanceUpdateWithFeePayer()" \
///  --account <account_name>
/// 4. > Add --broadcast to send the tx instead of simulating it.
/// 5. > Add --slow to force foundry to execute txs sequentially.
contract EarningChainGatewayInteractionScript is EarningChainBaseScript {
    function pushFundsToAccountingChain() public {
        address asset = USDT;
        uint256 amount = 123 * 10 ** 6;
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feeToken: LINK, feeAmount: 100000000000000000000, feeRefundThreshold: 0, gasLimit: 750000, data: ""
        });

        vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));
        address bridgeAdapter = address(0); // TODO: Set the whitelisted bridge adapter address.
        IEarningChainGateway(EARNING_CHAIN_GATEWAY)
            .pushFundsToAccountingChain(asset, amount, bridgeAdapter, BridgeParamsCodec.encode(bridgeParams));
        vm.stopBroadcast();
    }

    function addBridgeAdapter() public {
        address asset = USDT;
        uint256 chainId = 8453;
        address bridgeAdapter = 0x18b2b16456162B546AA8F3227C5d15B5aDd4ba41;

        vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));
        IEarningChainGateway(EARNING_CHAIN_GATEWAY).addBridgeAdapter(asset, chainId, bridgeAdapter);
        vm.stopBroadcast();
    }

    function getAggregatedBalance() public view returns (uint256) {
        return IEarningChainGateway(EARNING_CHAIN_GATEWAY).getAggregatedBalance();
    }
}
