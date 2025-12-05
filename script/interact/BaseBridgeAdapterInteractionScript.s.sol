// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {InteractionBaseScript} from "script/interact/InteractionBaseScript.s.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

contract BaseBridgeAdapterInteractionScript is InteractionBaseScript {
    function replayFundsReceiving(address baseBridgeAdapter, address asset, uint256 amount) public {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});

        // Anyone can call this function to replay the funds receiving process.
        vm.startBroadcast();
        IBridgeAdapter(baseBridgeAdapter).replayFundsReceiving(assets);
        vm.stopBroadcast();
    }
}
