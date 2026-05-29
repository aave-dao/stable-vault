// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {ICrossChainReceiver} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainReceiver.sol";
import {IWithGuardian} from "aave-delivery-infrastructure/contracts/old-oz/interfaces/IWithGuardian.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {AccessManager} from "openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import {IRescuable} from "solidity-utils/contracts/utils/interfaces/IRescuable.sol";

import {MockErc20} from "test/mocks/MockErc20.sol";

import {AdiAdapterPigeonLocalForkBase} from "./AdiAdapterPigeonLocalForkBase.sol";

contract NoopConfigurableAdapter {
    function setupPayments() external {}

    function config(uint256, bytes calldata) external {}
}

/// @notice Exercises the Stable Vaults AccessManager path for every a.DI CCC role.
contract AdiAdapterPigeonAccessManagerRoles is AdiAdapterPigeonLocalForkBase {
    uint32 internal constant ADI_ROLE_DELAY = 14 days;
    uint256 internal constant TEST_FORWARD_CHAIN_ID = 777_777;
    uint256 internal constant TEST_RECEIVER_CHAIN_ID = 888_888;

    function test_adiCccRoles_executeThroughAccessManager() public onlyForkTest {
        vm.selectFork(_ethFork);

        IAccessManager accessManager = _configureAccessManagerForCcc(_ethCcc);
        _transferCccOwnershipToAccessManager(accessManager);

        address testSender = makeAddr("ADI_TEST_SENDER");
        address testReceiverAdapter = makeAddr("ADI_TEST_RECEIVER_ADAPTER");
        NoopConfigurableAdapter forwarderAdapter = new NoopConfigurableAdapter();

        _assertDirectOwnerCallRejected(testSender);

        _executeViaAccessManager(
            accessManager, abi.encodeCall(ICrossChainForwarder.approveSenders, (_singleAddress(testSender)))
        );
        assertTrue(ICrossChainForwarder(_ethCcc).isSenderApproved(testSender), "sender not approved");

        _executeViaAccessManager(
            accessManager, abi.encodeCall(ICrossChainForwarder.removeSenders, (_singleAddress(testSender)))
        );
        assertFalse(ICrossChainForwarder(_ethCcc).isSenderApproved(testSender), "sender still approved");

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(ICrossChainForwarder.enableBridgeAdapters, (_forwarderBridgeConfig(forwarderAdapter)))
        );
        assertEq(
            ICrossChainForwarder(_ethCcc)
                .getForwarderBridgeAdaptersByChain(TEST_FORWARD_CHAIN_ID)[0].currentChainBridgeAdapter,
            address(forwarderAdapter),
            "forwarder adapter not enabled"
        );

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(
                ICrossChainForwarder.updateOptimalBandwidthByChain, (_optimalBandwidthConfig(TEST_FORWARD_CHAIN_ID, 1))
            )
        );
        assertEq(ICrossChainForwarder(_ethCcc).getOptimalBandwidthByChain(TEST_FORWARD_CHAIN_ID), 1);

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(
                ICrossChainForwarder.updateRequiredForwardingSuccessesByChain,
                (_requiredForwardingSuccessesConfig(TEST_FORWARD_CHAIN_ID, 1))
            )
        );
        assertEq(ICrossChainForwarder(_ethCcc).getRequiredForwardingSuccessesByChain(TEST_FORWARD_CHAIN_ID), 1);

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(
                ICrossChainForwarder.configAdapter,
                (TEST_FORWARD_CHAIN_ID, address(forwarderAdapter), abi.encode("noop"))
            )
        );

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(
                ICrossChainForwarder.disableBridgeAdapters, (_disableBridgeConfig(address(forwarderAdapter)))
            )
        );
        assertEq(ICrossChainForwarder(_ethCcc).getForwarderBridgeAdaptersByChain(TEST_FORWARD_CHAIN_ID).length, 0);

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(
                ICrossChainReceiver.allowReceiverBridgeAdapters, (_receiverBridgeConfig(testReceiverAdapter))
            )
        );
        assertTrue(
            ICrossChainReceiver(_ethCcc).isReceiverBridgeAdapterAllowed(testReceiverAdapter, TEST_RECEIVER_CHAIN_ID),
            "receiver adapter not allowed"
        );

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(ICrossChainReceiver.updateConfirmations, (_confirmationConfig(TEST_RECEIVER_CHAIN_ID, 1)))
        );
        assertEq(ICrossChainReceiver(_ethCcc).getConfigurationByChain(TEST_RECEIVER_CHAIN_ID).requiredConfirmation, 1);

        uint120 newValidityTimestamp = uint120(block.timestamp);
        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(
                ICrossChainReceiver.updateMessagesValidityTimestamp,
                (_validityTimestampConfig(TEST_RECEIVER_CHAIN_ID, newValidityTimestamp))
            )
        );
        assertEq(
            ICrossChainReceiver(_ethCcc).getConfigurationByChain(TEST_RECEIVER_CHAIN_ID).validityTimestamp,
            newValidityTimestamp
        );

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(
                ICrossChainReceiver.disallowReceiverBridgeAdapters, (_receiverBridgeConfig(testReceiverAdapter))
            )
        );
        assertFalse(
            ICrossChainReceiver(_ethCcc).isReceiverBridgeAdapterAllowed(testReceiverAdapter, TEST_RECEIVER_CHAIN_ID),
            "receiver adapter still allowed"
        );

        MockErc20 rescueToken = new MockErc20("Rescue Token", "RSQ", 18);
        address rescueRecipient = makeAddr("ADI_RESCUE_RECIPIENT");
        rescueToken.mint(_ethCcc, 1 ether);
        vm.deal(_ethCcc, 1 ether);

        _executeViaAccessManager(
            accessManager,
            abi.encodeCall(IRescuable.emergencyTokenTransfer, (address(rescueToken), rescueRecipient, 1 ether))
        );
        assertEq(rescueToken.balanceOf(rescueRecipient), 1 ether, "token rescue failed");

        uint256 recipientNativeBefore = rescueRecipient.balance;
        _executeViaAccessManager(
            accessManager, abi.encodeCall(IRescuable.emergencyEtherTransfer, (rescueRecipient, 1 ether))
        );
        assertEq(rescueRecipient.balance, recipientNativeBefore + 1 ether, "native rescue failed");

        address newGuardian = makeAddr("ADI_NEW_GUARDIAN");
        _executeViaAccessManager(accessManager, abi.encodeCall(IWithGuardian.updateGuardian, (newGuardian)));
        assertEq(IWithGuardian(_ethCcc).guardian(), newGuardian, "guardian not updated");

        address newOwner = makeAddr("ADI_NEW_OWNER");
        _executeViaAccessManager(accessManager, abi.encodeCall(Ownable.transferOwnership, (newOwner)));
        assertEq(Ownable(_ethCcc).owner(), newOwner, "owner not transferred");
    }

    function _configureAccessManagerForCcc(address ccc) internal returns (IAccessManager accessManager) {
        accessManager = IAccessManager(address(new AccessManager(address(this))));

        bytes4[15] memory selectors = _adiCccSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            uint64 roleId = _selectorToRoleId(selectors[i]);
            accessManager.setTargetFunctionRole(ccc, _singleSelector(selectors[i]), roleId);
            accessManager.grantRole(roleId, _stableVaultsOwner, ADI_ROLE_DELAY);
        }
    }

    function _transferCccOwnershipToAccessManager(IAccessManager accessManager) internal {
        vm.prank(_stableVaultsOwner);
        Ownable(_ethCcc).transferOwnership(address(accessManager));
        assertEq(Ownable(_ethCcc).owner(), address(accessManager), "CCC owner not transferred");
    }

    function _assertDirectOwnerCallRejected(address testSender) internal {
        vm.expectRevert();
        vm.prank(_stableVaultsOwner);
        ICrossChainForwarder(_ethCcc).approveSenders(_singleAddress(testSender));
    }

    function _executeViaAccessManager(IAccessManager accessManager, bytes memory data) internal {
        vm.prank(_stableVaultsOwner);
        accessManager.schedule(_ethCcc, data, 0);

        vm.warp(block.timestamp + ADI_ROLE_DELAY + 1);

        vm.prank(_stableVaultsOwner);
        accessManager.execute(_ethCcc, data);
    }

    function _adiCccSelectors() internal pure returns (bytes4[15] memory selectors) {
        selectors = [
            ICrossChainForwarder.approveSenders.selector,
            ICrossChainForwarder.removeSenders.selector,
            ICrossChainForwarder.enableBridgeAdapters.selector,
            ICrossChainForwarder.disableBridgeAdapters.selector,
            ICrossChainForwarder.updateOptimalBandwidthByChain.selector,
            ICrossChainForwarder.configAdapter.selector,
            ICrossChainForwarder.updateRequiredForwardingSuccessesByChain.selector,
            ICrossChainReceiver.updateConfirmations.selector,
            ICrossChainReceiver.updateMessagesValidityTimestamp.selector,
            ICrossChainReceiver.allowReceiverBridgeAdapters.selector,
            ICrossChainReceiver.disallowReceiverBridgeAdapters.selector,
            IRescuable.emergencyTokenTransfer.selector,
            IRescuable.emergencyEtherTransfer.selector,
            Ownable.transferOwnership.selector,
            IWithGuardian.updateGuardian.selector
        ];
    }

    function _selectorToRoleId(bytes4 selector) internal pure returns (uint64) {
        return uint64(bytes8(abi.encodePacked(selector, bytes4(0))));
    }

    function _singleSelector(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    function _forwarderBridgeConfig(NoopConfigurableAdapter adapter)
        internal
        pure
        returns (ICrossChainForwarder.ForwarderBridgeAdapterConfigInput[] memory config)
    {
        config = new ICrossChainForwarder.ForwarderBridgeAdapterConfigInput[](1);
        config[0] = ICrossChainForwarder.ForwarderBridgeAdapterConfigInput({
            currentChainBridgeAdapter: address(adapter),
            destinationBridgeAdapter: address(0xAD1),
            destinationChainId: TEST_FORWARD_CHAIN_ID
        });
    }

    function _disableBridgeConfig(address adapter)
        internal
        pure
        returns (ICrossChainForwarder.BridgeAdapterToDisable[] memory config)
    {
        config = new ICrossChainForwarder.BridgeAdapterToDisable[](1);
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = TEST_FORWARD_CHAIN_ID;
        config[0] = ICrossChainForwarder.BridgeAdapterToDisable({bridgeAdapter: adapter, chainIds: chainIds});
    }

    function _optimalBandwidthConfig(uint256 chainId, uint256 optimalBandwidth)
        internal
        pure
        returns (ICrossChainForwarder.OptimalBandwidthByChain[] memory config)
    {
        config = new ICrossChainForwarder.OptimalBandwidthByChain[](1);
        config[0] = ICrossChainForwarder.OptimalBandwidthByChain({chainId: chainId, optimalBandwidth: optimalBandwidth});
    }

    function _requiredForwardingSuccessesConfig(uint256 chainId, uint256 requiredSuccesses)
        internal
        pure
        returns (ICrossChainForwarder.RequiredForwardingSuccessesByChain[] memory config)
    {
        config = new ICrossChainForwarder.RequiredForwardingSuccessesByChain[](1);
        config[0] = ICrossChainForwarder.RequiredForwardingSuccessesByChain({
            chainId: chainId, requiredSuccesses: requiredSuccesses
        });
    }

    function _receiverBridgeConfig(address adapter)
        internal
        pure
        returns (ICrossChainReceiver.ReceiverBridgeAdapterConfigInput[] memory config)
    {
        config = new ICrossChainReceiver.ReceiverBridgeAdapterConfigInput[](1);
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = TEST_RECEIVER_CHAIN_ID;
        config[0] = ICrossChainReceiver.ReceiverBridgeAdapterConfigInput({bridgeAdapter: adapter, chainIds: chainIds});
    }

    function _confirmationConfig(uint256 chainId, uint8 requiredConfirmations)
        internal
        pure
        returns (ICrossChainReceiver.ConfirmationInput[] memory config)
    {
        config = new ICrossChainReceiver.ConfirmationInput[](1);
        config[0] =
            ICrossChainReceiver.ConfirmationInput({chainId: chainId, requiredConfirmations: requiredConfirmations});
    }

    function _validityTimestampConfig(uint256 chainId, uint120 validityTimestamp)
        internal
        pure
        returns (ICrossChainReceiver.ValidityTimestampInput[] memory config)
    {
        config = new ICrossChainReceiver.ValidityTimestampInput[](1);
        config[0] = ICrossChainReceiver.ValidityTimestampInput({chainId: chainId, validityTimestamp: validityTimestamp});
    }
}
