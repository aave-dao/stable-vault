// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccountingChainBaseScript} from "script/interact/accounting/AccountingChainBaseScript.s.sol";

import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";

/// @dev See example usage below:
/// 1. > export RPC_URL=<rpc-url>
/// 2. > cast wallet import <account_name> --private-key 0xYOUR_PRIVATE_KEY
/// 3. > forge script script/interact/accounting/FundsHandlerInteractionScript.s.sol \
///  --rpc-url $RPC_URL \
///  --sig "pushFundsToChain()" \
///  --account <account_name>
/// 4. > Add --broadcast to send the tx instead of simulating it.
/// 5. > Add --slow to force foundry to execute txs sequentially.
contract FundsHandlerInteractionScript is AccountingChainBaseScript {
    function pushFundsToChain() public {
        address token = GHO;
        uint256 amount = 234 * 10 ** 18;
        uint256 chainId = 1;
        ICcipBridgeAdapter.CcipFeeParams memory bridgeAdapterData =
            ICcipBridgeAdapter.CcipFeeParams({feeToken: LINK, feeAmount: 100000000000000000000, feeRefundThreshold: 0});
        uint256 gasLimit = 0; // TODO: Set the destination gas limit.

        uint256 key = vm.envUint("ADMIN_PRIVATE_KEY");
        vm.startBroadcast(key);
        address bridgeAdapter = address(0); // TODO: Set the whitelisted bridge adapter address.
        IFundsHandler(FUNDS_HANDLER)
            .pushFundsToChain(token, amount, chainId, bridgeAdapter, gasLimit, abi.encode(bridgeAdapterData));
        vm.stopBroadcast();
    }
}
