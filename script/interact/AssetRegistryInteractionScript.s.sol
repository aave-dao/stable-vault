// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {InteractionBaseScript} from "script/interact/InteractionBaseScript.s.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";

contract AssetRegistryInteractionScript is InteractionBaseScript {
    function enableFull(address assetRegistry, address asset) public {
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            withdrawFromAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));
        IAssetRegistry(assetRegistry).setAssetConfig(asset, config);
        vm.stopBroadcast();
    }
}
