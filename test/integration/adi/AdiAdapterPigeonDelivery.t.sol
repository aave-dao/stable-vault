// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Vm} from "forge-std/Vm.sol";

import {Constants} from "src/types/Constants.sol";

import {AdiHelper} from "pigeon/src/adi/AdiHelper.sol";

import {AdiAdapterPigeonLocalForkBase} from "./AdiAdapterPigeonLocalForkBase.sol";

/// @notice ETH/ARB delivery and ARB->ETH quorum behavior against local aDI + Pigeon.
contract AdiAdapterPigeonDelivery is AdiAdapterPigeonLocalForkBase {
    function test_ethToArb_pigeonFork_deliversViaLocalAdi() public onlyForkTest {
        bytes memory message = abi.encode("hello-arb");

        vm.selectFork(_ethFork);
        uint256 nativeFee = _prepareForwardFees(_ethAdiAdapter, ARB_CHAIN_ID, message);

        vm.recordLogs();
        _ethGateway.publishDataMessage{value: nativeFee}(
            ARB_CHAIN_ID, address(_ethAdiAdapter), address(this), DEFAULT_GAS_LIMIT, message
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_adiHelper.countSuccessfulForwards(logs), 1, "ETH->ARB should forward through one adapter");

        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: _ethCcc, logs: logs
            })
        );

        vm.selectFork(_arbFork);
        assertEq(_arbGateway.receiveCount(), 1, "ARB gateway did not receive");
        assertEq(_arbGateway.lastSourceChainId(), ETH_CHAIN_ID, "unexpected source chain");
        assertEq(_arbGateway.lastAsset(), Constants.ASSET_FOR_DATA_ONLY_BRIDGE, "unexpected asset");
        assertEq(_arbGateway.lastAmount(), 0, "unexpected amount");
        assertEq(abi.decode(_arbGateway.lastData(), (string)), "hello-arb", "unexpected message");
    }

    function test_arbToEth_pigeonFork_deliversViaTwoOfThree() public onlyForkTest {
        bytes memory message = abi.encode("hello-eth");

        vm.selectFork(_arbFork);
        uint256 nativeFee = _prepareForwardFees(_arbAdiAdapter, ETH_CHAIN_ID, message);

        vm.recordLogs();
        _arbGateway.publishDataMessage{value: nativeFee}(
            ETH_CHAIN_ID, address(_arbAdiAdapter), address(this), DEFAULT_GAS_LIMIT, message
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGe(_adiHelper.countSuccessfulForwards(logs), 2, "ARB->ETH should meet forwarding threshold");

        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: ETH_CCIP_ROUTER,
                dstCcipChainSelector: ETH_CCIP_CHAIN_SELECTOR,
                srcCcipOnRamp: address(0),
                dstLzEndpoint: LZ_ENDPOINT_V2,
                srcHlMailbox: ARB_HL_MAILBOX,
                dstHlMailbox: ETH_HL_MAILBOX,
                logs: logs
            })
        );

        vm.selectFork(_ethFork);
        assertEq(_ethGateway.receiveCount(), 1, "ETH gateway did not receive");
        assertEq(_ethGateway.lastSourceChainId(), ARB_CHAIN_ID, "unexpected source chain");
        assertEq(_ethGateway.lastAsset(), Constants.ASSET_FOR_DATA_ONLY_BRIDGE, "unexpected asset");
        assertEq(_ethGateway.lastAmount(), 0, "unexpected amount");
        assertEq(abi.decode(_ethGateway.lastData(), (string)), "hello-eth", "unexpected message");
    }

    /// @dev Relays one AMB at a time; destination should execute only after quorum, without duplicate gateway calls.
    function test_arbToEth_pigeonFork_quorumThenNoDuplicateDelivery() public onlyForkTest {
        bytes memory message = abi.encode("hello-quorum");

        vm.selectFork(_arbFork);
        uint256 nativeFee = _prepareForwardFees(_arbAdiAdapter, ETH_CHAIN_ID, message);

        vm.recordLogs();
        _arbGateway.publishDataMessage{value: nativeFee}(
            ETH_CHAIN_ID, address(_arbAdiAdapter), address(this), DEFAULT_GAS_LIMIT, message
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGe(_adiHelper.countSuccessfulForwards(logs), 2, "ARB->ETH should meet forwarding threshold");

        uint256 quorum = _arbToEthQuorum();
        vm.selectFork(_ethFork);
        assertEq(_ethGateway.receiveCount(), 0, "ETH gateway should not receive before quorum");

        // Relay one bridge at a time: the gateway receives exactly once, when the quorum-th confirmation lands, and
        // over-quorum relays do not duplicate the receive. Quorum is read on-chain (e.g. 3-of-3
        // prod/canary).
        for (uint256 confirmations = 1; confirmations <= 3; confirmations++) {
            _relayArbToEthSingleAmb(logs, confirmations - 1);
            vm.selectFork(_ethFork);
            uint256 expected = confirmations >= quorum ? 1 : 0;
            assertEq(_ethGateway.receiveCount(), expected, "gateway receiveCount wrong for confirmation stage");
        }
        assertEq(abi.decode(_ethGateway.lastData(), (string)), "hello-quorum", "unexpected message");
    }
}
