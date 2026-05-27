// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {Envelope} from "aave-delivery-infrastructure/contracts/libs/EncodingUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {Constants} from "src/types/Constants.sol";

import {AdiHelper} from "pigeon/src/adi/AdiHelper.sol";

import {AdiAdapterPigeonLocalForkBase} from "./AdiAdapterPigeonLocalForkBase.sol";

/// @notice Retry paths (`retryTransaction`, `retryEnvelope`) against local aDI + Pigeon.
contract AdiAdapterPigeonRetry is AdiAdapterPigeonLocalForkBase {
    function test_retryTransaction_pigeonFork_deliversViaLocalAdiGuardian() public onlyForkTest {
        bytes memory message = abi.encode("retry-hello-arb");
        address[] memory bridgeAdaptersToRetry = _singleAddress(_ethArbAdapter);

        vm.selectFork(_ethFork);
        uint256 forwardNativeFee = _prepareForwardFees(_ethAdiAdapter, ARB_CHAIN_ID, message);

        vm.recordLogs();
        _ethGateway.publishDataMessage{value: forwardNativeFee}(
            ARB_CHAIN_ID, address(_ethAdiAdapter), address(this), DEFAULT_GAS_LIMIT, message
        );
        Vm.Log[] memory forwardLogs = vm.getRecordedLogs();
        bytes memory encodedTransaction = _firstSuccessfulEncodedTransaction(forwardLogs);

        vm.selectFork(_arbFork);
        assertEq(_arbGateway.receiveCount(), 0, "original transaction should not be relayed");

        vm.selectFork(_ethFork);
        _setGuardian(_ethCcc, _stableVaultsOwner);
        uint256 retryNativeFee = _prepareRetryFees(_ethAdiAdapter, encodedTransaction, bridgeAdaptersToRetry);

        vm.expectRevert();
        _ethAdiAdapter.retryTransaction{value: retryNativeFee}(
            encodedTransaction, DEFAULT_GAS_LIMIT, bridgeAdaptersToRetry
        );

        _setGuardian(_ethCcc, address(_ethAdiAdapter));
        retryNativeFee = _prepareRetryFees(_ethAdiAdapter, encodedTransaction, bridgeAdaptersToRetry);

        vm.recordLogs();
        _ethAdiAdapter.retryTransaction{value: retryNativeFee}(
            encodedTransaction, DEFAULT_GAS_LIMIT, bridgeAdaptersToRetry
        );
        Vm.Log[] memory retryLogs = vm.getRecordedLogs();

        assertEq(_adiHelper.countSuccessfulForwards(retryLogs), 1, "retry should forward through one adapter");

        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: _ethCcc, logs: retryLogs
            })
        );

        vm.selectFork(_arbFork);
        assertEq(_arbGateway.receiveCount(), 1, "ARB gateway did not receive retry");
        assertEq(_arbGateway.lastSourceChainId(), ETH_CHAIN_ID, "unexpected source chain");
        assertEq(_arbGateway.lastAsset(), Constants.ASSET_FOR_DATA_ONLY_BRIDGE, "unexpected asset");
        assertEq(_arbGateway.lastAmount(), 0, "unexpected amount");
        assertEq(abi.decode(_arbGateway.lastData(), (string)), "retry-hello-arb", "unexpected retry message");
    }

    function test_retryEnvelope_pigeonFork_deliversViaLocalAdiGuardian() public onlyForkTest {
        bytes memory message = abi.encode("retry-envelope-arb");

        vm.selectFork(_ethFork);
        uint256 forwardNativeFee = _prepareForwardFees(_ethAdiAdapter, ARB_CHAIN_ID, message);

        vm.recordLogs();
        _ethGateway.publishDataMessage{value: forwardNativeFee}(
            ARB_CHAIN_ID, address(_ethAdiAdapter), address(this), DEFAULT_GAS_LIMIT, message
        );
        Vm.Log[] memory forwardLogs = vm.getRecordedLogs();
        Envelope memory envelope = _envelopeFromFirstSuccessfulForward(forwardLogs);

        vm.selectFork(_arbFork);
        assertEq(_arbGateway.receiveCount(), 0, "original envelope should not be relayed");

        vm.selectFork(_ethFork);
        _setGuardian(_ethCcc, _stableVaultsOwner);
        uint256 quoteBw = ICrossChainForwarder(_ethCcc).getOptimalBandwidthByChain(envelope.destinationChainId);
        uint256 badRetryFee;
        (badRetryFee,,) = _ethAdiAdapter.quoteRetryEnvelope(envelope, DEFAULT_GAS_LIMIT, quoteBw);
        vm.deal(address(this), badRetryFee);

        vm.expectRevert();
        _ethAdiAdapter.retryEnvelope{value: badRetryFee}(envelope, DEFAULT_GAS_LIMIT);

        _setGuardian(_ethCcc, address(_ethAdiAdapter));
        uint256 retryNativeFee = _prepareRetryEnvelopeFees(_ethAdiAdapter, envelope);

        vm.recordLogs();
        bytes32 transactionId = _ethAdiAdapter.retryEnvelope{value: retryNativeFee}(envelope, DEFAULT_GAS_LIMIT);
        Vm.Log[] memory retryLogs = vm.getRecordedLogs();
        assertNotEq(transactionId, bytes32(0), "retry envelope transaction id should be non-zero");

        assertEq(_adiHelper.countSuccessfulForwards(retryLogs), 1, "retry envelope should forward through one adapter");

        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: _ethCcc, logs: retryLogs
            })
        );

        vm.selectFork(_arbFork);
        assertEq(_arbGateway.receiveCount(), 1, "ARB gateway did not receive retry envelope");
        assertEq(_arbGateway.lastSourceChainId(), ETH_CHAIN_ID, "unexpected source chain");
        assertEq(_arbGateway.lastAsset(), Constants.ASSET_FOR_DATA_ONLY_BRIDGE, "unexpected asset");
        assertEq(_arbGateway.lastAmount(), 0, "unexpected amount");
        assertEq(abi.decode(_arbGateway.lastData(), (string)), "retry-envelope-arb", "unexpected retry message");
    }
}
