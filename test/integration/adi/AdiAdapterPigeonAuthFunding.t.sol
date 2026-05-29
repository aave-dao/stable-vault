// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

import {AdiAdapterPigeonLocalForkBase, RecordingGateway} from "./AdiAdapterPigeonLocalForkBase.sol";

/// @notice Authorization and native overpay refund behavior on local aDI forks.
contract AdiAdapterPigeonAuthFunding is AdiAdapterPigeonLocalForkBase {
    function test_publish_reverts_whenEthAdapterNotApprovedByCcc() public onlyForkTest {
        vm.selectFork(_ethFork);

        RecordingGateway rogueGateway = new RecordingGateway();
        MockAccessManager accessManager = new MockAccessManager(_cccOwnerOf(_ethCcc));
        MockTransferHelper transferHelper = new MockTransferHelper();
        AdiAdapter rogueAdapter =
            new AdiAdapter(address(accessManager), address(rogueGateway), _ethCcc, address(transferHelper));

        vm.startPrank(_cccOwnerOf(_ethCcc));
        rogueAdapter.setDestinationChainAdapter(ARB_CHAIN_ID, address(_arbAdiAdapter));
        vm.stopPrank();

        bytes memory message = abi.encode("unapproved-sender");
        uint256 nativeFee = _prepareForwardFees(rogueAdapter, ARB_CHAIN_ID, message);
        vm.deal(address(rogueGateway), nativeFee);

        vm.expectRevert();
        vm.prank(address(rogueGateway));
        rogueAdapter.publishDataOnlyMessage{value: nativeFee}(
            ARB_CHAIN_ID, message, address(this), DEFAULT_GAS_LIMIT, ""
        );
    }

    function test_ethToArb_overpayRefundsExcessNativeToFeePayer() public onlyForkTest {
        address feePayer = makeAddr("FORK_FEE_PAYER");
        vm.deal(feePayer, 0);

        bytes memory message = abi.encode("overpay");
        vm.selectFork(_ethFork);
        uint256 nativeFee = _prepareForwardFees(_ethAdiAdapter, ARB_CHAIN_ID, message);
        uint256 extra = 0.25 ether;
        uint256 paid = nativeFee + extra;
        vm.deal(address(_ethGateway), paid);

        uint256 feePayerBefore = feePayer.balance;

        vm.prank(address(_ethGateway));
        _ethGateway.publishDataMessage{value: paid}(
            ARB_CHAIN_ID, address(_ethAdiAdapter), feePayer, DEFAULT_GAS_LIMIT, message
        );

        assertEq(address(_ethAdiAdapter).balance, 0, "adapter should not retain native");
        assertEq(feePayer.balance, feePayerBefore + extra, "fee payer should receive excess native refund");
    }
}
