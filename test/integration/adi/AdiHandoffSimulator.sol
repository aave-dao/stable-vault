// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

interface IAdiHandoffAdmin {
    function approveSenders(address[] memory senders) external;
    function updateGuardian(address newGuardian) external;
}

/// @dev Simulates the a.DI owner/guardian handoff to the Stable Vaults contracts on a fork, for environments whose
/// on-chain a.DI is intentionally left un-finalized. The canary deployment keeps the CCC owner/guardian on the
/// deployer EOA (so the live test can tweak LayerZero DVN config instantly), whereas preprod/prod already handed off
/// to the deterministic AccessManager / AdiAdapter on-chain. The Stable Vaults deploy's `_validateAdiConfiguration`
/// and the deploy fork tests both require owner == AccessManager and guardian == AdiAdapter, so this reproduces what
/// `FinalizeAccessControl` does on the real chains: approve the deterministic adapter as a CCC sender, make it the
/// guardian, and transfer ownership to the deterministic AccessManager. It is a no-op when the handoff already
/// happened on-chain, so a single harness path serves every environment.
abstract contract AdiHandoffSimulator is Test {
    function _finalizeAdiHandoffOnForkIfNeeded(address crossChainController, address accessManager, address adiAdapter)
        internal
    {
        address currentOwner = Ownable(crossChainController).owner();
        if (currentOwner == accessManager) {
            return;
        }

        address[] memory senders = new address[](1);
        senders[0] = adiAdapter;

        vm.startPrank(currentOwner);
        IAdiHandoffAdmin(crossChainController).approveSenders(senders);
        IAdiHandoffAdmin(crossChainController).updateGuardian(adiAdapter);
        Ownable(crossChainController).transferOwnership(accessManager);
        vm.stopPrank();
    }
}
