// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {InteractionBaseScript} from "script/interact/InteractionBaseScript.s.sol";

import {IAllocator} from "src/interfaces/IAllocator.sol";

contract AllocatorInteractionScript is InteractionBaseScript {
    function getAssetBalances(address allocator) public view returns (IAllocator.AllocatorBalance[] memory) {
        return IAllocator(allocator).getAssetBalances();
    }

    function allocate(address allocator, address asset, address strategy, uint256 amount) public {
        IAllocator.AllocationParams memory allocation =
            IAllocator.AllocationParams({asset: asset, strategy: strategy, amount: amount});
        IAllocator.AllocationParams[] memory allocations = new IAllocator.AllocationParams[](1);
        allocations[0] = allocation;
        IAllocator.RebalanceParams memory rebalanceParam = IAllocator.RebalanceParams({
            deallocations: new IAllocator.DeallocationParams[](0),
            swaps: new IAllocator.SwapParams[](0),
            allocations: allocations
        });
        IAllocator.RebalanceParams[] memory rebalanceParams = new IAllocator.RebalanceParams[](1);
        rebalanceParams[0] = rebalanceParam;

        vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));
        IAllocator(allocator).rebalance(rebalanceParams);
        vm.stopBroadcast();
    }
}
