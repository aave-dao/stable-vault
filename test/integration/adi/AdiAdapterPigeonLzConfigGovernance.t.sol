// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {Test} from "forge-std/Test.sol";
import {IAccessManager} from "openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {AdiHandoffSimulator} from "./AdiHandoffSimulator.sol";
import {AccountingChainForkHarness} from "./PreprodForkHarnesses.sol";

/// @dev LayerZero V2 EndpointV2 surface used to read OApp config / delegate.
interface ILzEndpointGov {
    function delegates(address oapp) external view returns (address);
}

interface ILzAdapterEndpoint {
    function LZ_ENDPOINT() external view returns (address);
}

interface ICccForwarderAdaptersView {
    struct ChainIdBridgeConfig {
        address destinationBridgeAdapter;
        address currentChainBridgeAdapter;
    }

    function getForwarderBridgeAdaptersByChain(uint256 chainId) external view returns (ChainIdBridgeConfig[] memory);
}

/// @notice Regression coverage for the production LayerZero-config governance path on the deployed Stable Vaults
/// system: the MainAdmin profile can change the a.DI LayerZero configuration only by routing
/// `CrossChainForwarder.configAdapter` through the deployed AccessManager (which owns the CrossChainController),
/// honoring the AccessManager's schedule -> critical-delay -> execute flow. The change is observed on the real
/// LayerZero EndpointV2 (the OApp delegate is updated), exercising the full MainAdmin -> AccessManager -> CCC ->
/// LZ-adapter -> EndpointV2 chain rather than a throwaway AccessManager + noop adapter.
contract AdiAdapterPigeonLzConfigGovernance is Test, AdiHandoffSimulator {
    uint256 internal constant ARB_CHAIN_ID = 42161;
    uint256 internal constant ETH_CHAIN_ID = 1;

    modifier onlyForkTest() {
        vm.skip(!vm.envOr("FORK_TEST", false), "Set FORK_TEST=true to run the LZ config governance fork test");
        _;
    }

    function test_mainAdmin_setsLzDelegate_viaAccessManager() public onlyForkTest {
        vm.createSelectFork(vm.envOr("ARB_FORK_RPC", string("http://127.0.0.1:8546")));
        assertEq(block.chainid, ARB_CHAIN_ID, "expected Arbitrum fork");

        // Deploy the accounting-chain Stable Vaults system so the assertions run against the real deployed
        // AccessManager and the real MainAdmin role grants. The handoff is a no-op on already-finalized a.DI
        // (preprod/prod) and
        // simulated on un-finalized a.DI; either way the AccessManager ends up owning the CrossChainController.
        AccountingChainForkHarness deployment = new AccountingChainForkHarness();
        deployment.redirectOutputTo("deployments/lzgov-accounting.forktest.json");
        address arbCcc = deployment.adiCccAddr();
        address accessManager = deployment.accessManagerAddr();

        address deployer = deployment.deployerAddr();
        vm.deal(deployer, 1000 ether);
        deal(deployment.gho(), deployer, 1_000e18);
        deal(deployment.usdc(), deployer, 1_000e6);
        deal(deployment.usdt(), deployer, 1_000e6);

        _finalizeAdiHandoffOnForkIfNeeded(arbCcc, accessManager, deployment.adiAdapterAddr());
        deployment.run();

        assertEq(Ownable(arbCcc).owner(), accessManager, "AccessManager should own the CCC after deploy");

        address mainAdmin = deployment.mainAdminAddr();
        address lzAdapter = _findForwarderLzAdapter(arbCcc, ETH_CHAIN_ID);
        assertNotEq(lzAdapter, address(0), "no LZ adapter in ARB CCC forwarder set for destination Ethereum");

        ILzEndpointGov endpoint = ILzEndpointGov(ILzAdapterEndpoint(lzAdapter).LZ_ENDPOINT());

        address newDelegate = makeAddr("LZ_CONFIG_GOV_DELEGATE");
        assertNotEq(endpoint.delegates(arbCcc), newDelegate, "delegate unexpectedly already set");

        // MainAdmin cannot touch the CCC directly; only the AccessManager (its owner) can, and MainAdmin must route
        // through it with the critical delay.
        _scheduleAndExecuteAsMainAdmin(
            accessManager,
            mainAdmin,
            arbCcc,
            abi.encodeCall(ICrossChainForwarder.configAdapter, (ETH_CHAIN_ID, lzAdapter, abi.encode(newDelegate)))
        );

        assertEq(
            endpoint.delegates(arbCcc), newDelegate, "LZ endpoint delegate not updated via MainAdmin -> AccessManager"
        );
    }

    /// @dev Route a call through the deployed AccessManager as `actor`, honoring its execution delay: schedule, warp to
    /// the scheduled timepoint, then execute.
    function _scheduleAndExecuteAsMainAdmin(address accessManager, address actor, address target, bytes memory data)
        internal
    {
        IAccessManager am = IAccessManager(accessManager);

        vm.prank(actor);
        am.schedule(target, data, 0);

        bytes32 operationId = am.hashOperation(actor, target, data);
        vm.warp(am.getSchedule(operationId));

        vm.prank(actor);
        am.execute(target, data);
    }

    function _findForwarderLzAdapter(address ccc, uint256 destinationChainId) internal view returns (address) {
        ICccForwarderAdaptersView.ChainIdBridgeConfig[] memory cfgs =
            ICccForwarderAdaptersView(ccc).getForwarderBridgeAdaptersByChain(destinationChainId);
        for (uint256 i = 0; i < cfgs.length; i++) {
            address a = cfgs[i].currentChainBridgeAdapter;
            if (a.code.length == 0) {
                continue;
            }
            try ILzAdapterEndpoint(a).LZ_ENDPOINT() returns (address ep) {
                if (ep != address(0)) {
                    return a;
                }
            } catch {
                // not an LZ-style adapter
            }
        }
        return address(0);
    }
}
