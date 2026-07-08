// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AdiAdapterPigeonLocalForkBase} from "./AdiAdapterPigeonLocalForkBase.sol";

/// @notice Deployment invariants from `adi-deploy` JSON (optional env vars from `run-adi-pigeon-fork-test.sh`).
contract AdiAdapterPigeonConfig is AdiAdapterPigeonLocalForkBase {
    function test_deployedBridgeAdapters_nonZeroCode() public onlyForkTest {
        assertNotEq(_ethCcipAdapter, address(0), "ETH_CCIP_ADAPTER not set");
        assertNotEq(_ethLzAdapter, address(0), "ETH_LZ_ADAPTER not set");
        assertNotEq(_ethHlAdapter, address(0), "ETH_HL_ADAPTER not set");
        assertNotEq(_arbCcipAdapter, address(0), "ARB_CCIP_ADAPTER not set");
        assertNotEq(_arbLzAdapter, address(0), "ARB_LZ_ADAPTER not set");
        assertNotEq(_arbHlAdapter, address(0), "ARB_HL_ADAPTER not set");

        vm.selectFork(_ethFork);
        assertGt(_ethCcipAdapter.code.length, 0, "ETH CCIP adapter should be deployed");
        assertGt(_ethLzAdapter.code.length, 0, "ETH LZ adapter should be deployed");
        assertGt(_ethHlAdapter.code.length, 0, "ETH HL adapter should be deployed");

        vm.selectFork(_arbFork);
        assertGt(_arbCcipAdapter.code.length, 0, "ARB CCIP adapter should be deployed");
        assertGt(_arbLzAdapter.code.length, 0, "ARB LZ adapter should be deployed");
        assertGt(_arbHlAdapter.code.length, 0, "ARB HL adapter should be deployed");
    }

    function test_cccProxies_nonZeroCode() public onlyForkTest {
        vm.selectFork(_ethFork);
        assertGt(_ethCcc.code.length, 0, "ETH CCC should exist");
        vm.selectFork(_arbFork);
        assertGt(_arbCcc.code.length, 0, "ARB CCC should exist");
    }
}
