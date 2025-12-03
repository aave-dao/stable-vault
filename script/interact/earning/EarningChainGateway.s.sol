// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {EarningChainBaseScript} from "script/interact/earning/EarningChainBaseScript.s.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";

contract EarningChainGateway is EarningChainBaseScript {
    address constant EARNING_CHAIN_GATEWAY = 0xb93E374aF729E77e42294791c20F947e7BdFFdE6;

    function sendBalanceUpdateWithFeePayer() public {
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(0xC9213f6189b0f4F96Ba859c675589755178ae276),
            feeToken: LINK,
            feeAmount: 100000000000000000000,
            feeRefundThreshold: 0,
            gasLimit: 750000,
            data: ""
        });

        vm.startBroadcast();
        IEarningChainGateway(EARNING_CHAIN_GATEWAY).sendBalanceUpdateWithFeePayer{value: 0}(bridgeParams);
        vm.stopBroadcast();
    }
}
