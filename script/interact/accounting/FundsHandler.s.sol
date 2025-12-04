// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccountingChainBaseScript} from "script/interact/accounting/AccountingChainBaseScript.s.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";

/// @dev See example usage below:
/// 1. > export RPC_URL=<rpc-url>
/// 2. > cast wallet import <account_name> --private-key 0xYOUR_PRIVATE_KEY
/// 3. > forge script script/interact/accounting/FundsHandler.s.sol \
///  --rpc-url $RPC_URL \
///  --sig "pushFundsToChain()" \
///  --account <account_name> \
///  --broadcast // leave this out to simular the tx
contract FundsHandler is AccountingChainBaseScript {
    address constant FUNDS_HANDLER = 0xd2F851e7A5f4f43B3347376cd93824524A1b0187;

    function pushFundsToChain() public {
        address token = USDC;
        uint256 amount = 2000000;
        uint256 chainId = 1;
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(0xC9213f6189b0f4F96Ba859c675589755178ae276),
            feeToken: LINK,
            // 105397943148798144
            feeAmount: 100000000000000000000,
            feeRefundThreshold: 0,
            gasLimit: 750000,
            data: ""
        });

        uint256 key = vm.envUint("ADMIN_PRIVATE_KEY");
        vm.startBroadcast(key);
        IFundsHandler(FUNDS_HANDLER).pushFundsToChain(token, amount, chainId, bridgeParams);
        vm.stopBroadcast();
    }
}
