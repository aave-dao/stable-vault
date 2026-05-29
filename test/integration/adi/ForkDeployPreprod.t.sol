// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IWithGuardian} from "aave-delivery-infrastructure/contracts/old-oz/interfaces/IWithGuardian.sol";

import {BaseBridgeAdapter} from "src/bridging/BaseBridgeAdapter.sol";
import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {BaseChainGateway} from "src/core/BaseChainGateway.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";

import {AccountingChainForkHarness, EarningChainForkHarness} from "./PreprodForkHarnesses.sol";

interface ICccSenders {
    function isSenderApproved(address sender) external view returns (bool);
}

/// @notice Runs the real preprod deployment scripts against local Ethereum/Arbitrum forks where the a.DI owner/guardian
/// handoff has already executed, and checks that the deterministic AccessManager / AdiAdapter land at the addresses
/// a.DI handed control to and that the deployed adapter is wired for bridging. Skipped unless FORK_TEST=true; run via
/// run-adi-pigeon-fork-test.sh, which boots the forks and points ETH_FORK_RPC / ARB_FORK_RPC at them.
contract ForkDeployPreprod is Test {
    uint256 internal constant ETH_CHAIN_ID = 1;
    uint256 internal constant ARB_CHAIN_ID = 42161;

    string internal constant EARNING_OUTPUT = "deployments/preprod/v1/earning.forktest.json";
    string internal constant ACCOUNTING_OUTPUT = "deployments/preprod/v1/accounting.forktest.json";

    address internal constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address internal constant ARB_GHO = 0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    modifier onlyForkTest() {
        vm.skip(!vm.envOr("FORK_TEST", false), "Set FORK_TEST=true to run preprod fork deployment");
        _;
    }

    function test_deployEarningChain_onEthFork() external onlyForkTest {
        vm.createSelectFork(vm.envOr("ETH_FORK_RPC", string("http://127.0.0.1:8545")));
        assertEq(block.chainid, ETH_CHAIN_ID, "expected Ethereum fork for earning chain");

        EarningChainForkHarness deployment = new EarningChainForkHarness();
        deployment.redirectOutputTo(EARNING_OUTPUT);

        address deployer = deployment.deployerAddr();
        vm.deal(deployer, 1000 ether);
        deal(ETH_USDC, deployer, 1_000e6);
        deal(ETH_USDT, deployer, 1_000e6);

        deployment.run();

        _assertCoreAddresses(deployment.adiCccAddr(), deployment.accessManagerAddr(), deployment.adiAdapterAddr());
        _assertAdapterWired(
            deployment.gatewayAddr(), deployment.adiAdapterAddr(), deployment.adiCccAddr(), ARB_CHAIN_ID
        );
    }

    function test_deployAccountingChain_onArbFork() external onlyForkTest {
        vm.createSelectFork(vm.envOr("ARB_FORK_RPC", string("http://127.0.0.1:8546")));
        assertEq(block.chainid, ARB_CHAIN_ID, "expected Arbitrum fork for accounting chain");

        AccountingChainForkHarness deployment = new AccountingChainForkHarness();
        deployment.redirectOutputTo(ACCOUNTING_OUTPUT);

        address deployer = deployment.deployerAddr();
        vm.deal(deployer, 1000 ether);
        deal(ARB_GHO, deployer, 1_000e18);
        deal(ARB_USDC, deployer, 1_000e6);
        deal(ARB_USDT, deployer, 1_000e6);

        deployment.run();

        _assertCoreAddresses(deployment.adiCccAddr(), deployment.accessManagerAddr(), deployment.adiAdapterAddr());
        _assertAdapterWired(
            deployment.gatewayAddr(), deployment.adiAdapterAddr(), deployment.adiCccAddr(), ETH_CHAIN_ID
        );
    }

    /// @dev The deterministic AccessManager/AdiAdapter must exist and own/guard the CCC, proving the a.DI handoff
    /// targeted the exact addresses the deploy lands on.
    function _assertCoreAddresses(address ccc, address accessManager, address adiAdapter) internal view {
        assertGt(accessManager.code.length, 0, "AccessManager not deployed at expected address");
        assertGt(adiAdapter.code.length, 0, "AdiAdapter not deployed at expected address");
        assertEq(Ownable(ccc).owner(), accessManager, "CCC owner is not the deployed AccessManager");
        assertEq(IWithGuardian(ccc).guardian(), adiAdapter, "CCC guardian is not the deployed AdiAdapter");
    }

    function _assertAdapterWired(address gateway, address adapter, address ccc, uint256 remoteChainId) internal view {
        assertEq(AdiAdapter(adapter).getCrossChainController(), ccc, "adapter not bound to configured CCC");
        // The adapter has the same address on both chains (CREATE3 + same deployer/salt), so it points at itself.
        assertEq(
            BaseBridgeAdapter(adapter).getDestinationChainAdapter(remoteChainId), adapter, "destination adapter not set"
        );
        assertTrue(
            BaseChainGateway(gateway).getDataOnlyBridgeAdapterMode(remoteChainId, adapter)
                == IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE,
            "adapter not registered as data-only bridge on gateway"
        );
        // a.DI-side approval (done during the handoff) must accept the deployed adapter as a forwarder.
        assertTrue(ICccSenders(ccc).isSenderApproved(adapter), "deployed adapter not approved as CCC sender");
        // The deployed adapter can quote a real cross-chain send through the CCC's configured bridge adapters.
        (,, uint256 successfulQuotes) =
            AdiAdapter(adapter).quoteMessageToChain(remoteChainId, bytes("sv-fork-probe"), 200_000);
        assertGt(successfulQuotes, 0, "deployed adapter cannot quote a cross-chain message via CCC");
    }
}
