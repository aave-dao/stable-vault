// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonNativeRecipient} from "test/mocks/MockNonNativeRecipient.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";

contract TransferHelperTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IMockErc20;

    TransferHelper transferHelper;

    function setUp() public {
        transferHelper = new TransferHelper();
    }

    function test_pull_singleErc20(
        address msgSender,
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 assetAmount,
        uint256 pullAmount
    ) public {
        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(transferHelper));
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        assetAmount = _boundAssetAmount(asset, assetAmount);
        pullAmount = _boundAssetAmount(asset, pullAmount);
        vm.assume(pullAmount <= assetAmount);
        IMockErc20(asset).mint(address(transferHelper), assetAmount);

        vm.prank(msgSender);
        transferHelper.pull(asset, pullAmount);

        assertEq(IMockErc20(asset).balanceOf(address(transferHelper)), transferHelper.getBalance(asset));
        assertEq(IMockErc20(asset).balanceOf(address(transferHelper)), assetAmount - pullAmount);
        assertEq(IMockErc20(asset).balanceOf(msgSender), pullAmount);
    }

    function test_pull_multipleErc20(
        address msgSender,
        bytes32 assetDeploymentSalt1,
        uint8 assetDecimals1,
        uint256 assetAmount1,
        uint256 pullAmount1,
        bytes32 assetDeploymentSalt2,
        uint8 assetDecimals2,
        uint256 assetAmount2,
        uint256 pullAmount2
    ) public {
        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(transferHelper));
        vm.assume(assetDeploymentSalt1 != assetDeploymentSalt2);

        address asset1 = _deployAssetWithSalt(assetDeploymentSalt1, assetDecimals1);
        assetAmount1 = _boundAssetAmount(asset1, assetAmount1);
        pullAmount1 = _boundAssetAmount(asset1, pullAmount1);
        vm.assume(pullAmount1 <= assetAmount1);
        IMockErc20(asset1).mint(address(transferHelper), assetAmount1);

        address asset2 = _deployAssetWithSalt(assetDeploymentSalt2, assetDecimals2);
        assetAmount2 = _boundAssetAmount(asset2, assetAmount2);
        pullAmount2 = _boundAssetAmount(asset2, pullAmount2);
        vm.assume(pullAmount2 <= assetAmount2);
        IMockErc20(asset2).mint(address(transferHelper), assetAmount2);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = pullAmount1;
        amounts[1] = pullAmount2;

        vm.prank(msgSender);
        transferHelper.pull(assets, amounts);

        assertEq(IMockErc20(asset1).balanceOf(address(transferHelper)), transferHelper.getBalance(asset1));
        assertEq(IMockErc20(asset1).balanceOf(address(transferHelper)), assetAmount1 - pullAmount1);
        assertEq(IMockErc20(asset1).balanceOf(msgSender), pullAmount1);

        assertEq(IMockErc20(asset2).balanceOf(address(transferHelper)), transferHelper.getBalance(asset2));
        assertEq(IMockErc20(asset2).balanceOf(address(transferHelper)), assetAmount2 - pullAmount2);
        assertEq(IMockErc20(asset2).balanceOf(msgSender), pullAmount2);
    }

    function test_pull_native(address msgSender, uint256 nativeAmount, uint256 pullAmount) public {
        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(transferHelper));
        vm.assume(msgSender.balance == 0);
        _assumeCanReceiveNative(msgSender);

        nativeAmount = _boundNativeAmount(nativeAmount);
        pullAmount = _boundNativeAmount(pullAmount);
        vm.assume(pullAmount <= nativeAmount);
        vm.deal(address(transferHelper), nativeAmount);

        vm.prank(msgSender);
        transferHelper.pull(address(0), pullAmount);

        assertEq(address(transferHelper).balance, transferHelper.getBalance(address(0)));
        assertEq(address(transferHelper).balance, nativeAmount - pullAmount);
        assertEq(msgSender.balance, pullAmount);
    }

    function test_pull_reverts_nativeNotSupportedByRecipient(
        bytes32 msgSenderDeploymentSalt,
        uint256 nativeAmount,
        uint256 pullAmount
    ) public {
        address msgSender = address(new MockNonNativeRecipient{salt: msgSenderDeploymentSalt}());

        nativeAmount = _boundNativeAmount(nativeAmount);
        pullAmount = _boundNativeAmount(pullAmount);
        vm.assume(pullAmount <= nativeAmount);
        vm.deal(address(transferHelper), nativeAmount);

        vm.prank(msgSender);
        vm.expectRevert(abi.encodeWithSelector(Errors.NativeTransferFailed.selector));
        transferHelper.pull(address(0), pullAmount);
    }

    function test_pull_nativeAndErc20(
        address msgSender,
        uint256 nativeAmount,
        uint256 nativePullAmount,
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 assetAmount,
        uint256 assetPullAmount
    ) public {
        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(transferHelper));
        vm.assume(msgSender.balance == 0);
        _assumeCanReceiveNative(msgSender);

        nativeAmount = _boundNativeAmount(nativeAmount);
        nativePullAmount = _boundNativeAmount(nativePullAmount);
        vm.assume(nativePullAmount <= nativeAmount);
        vm.deal(address(transferHelper), nativeAmount);

        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        assetAmount = _boundAssetAmount(asset, assetAmount);
        assetPullAmount = _boundAssetAmount(asset, assetPullAmount);
        vm.assume(assetPullAmount <= assetAmount);
        IMockErc20(asset).mint(address(transferHelper), assetAmount);

        address[] memory assets = new address[](2);
        assets[0] = address(0);
        assets[1] = asset;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = nativePullAmount;
        amounts[1] = assetPullAmount;

        vm.prank(msgSender);
        transferHelper.pull(assets, amounts);

        assertEq(address(transferHelper).balance, transferHelper.getBalance(address(0)));
        assertEq(address(transferHelper).balance, nativeAmount - nativePullAmount);
        assertEq(msgSender.balance, nativePullAmount);

        assertEq(IMockErc20(asset).balanceOf(address(transferHelper)), transferHelper.getBalance(asset));
        assertEq(IMockErc20(asset).balanceOf(address(transferHelper)), assetAmount - assetPullAmount);
        assertEq(IMockErc20(asset).balanceOf(msgSender), assetPullAmount);
    }

    function test_transfer_singleErc20(
        address msgSender,
        address destination,
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 assetAmount,
        uint256 pullAmount
    ) public {
        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(transferHelper));
        vm.assume(destination != address(0));
        vm.assume(destination != address(transferHelper));

        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        assetAmount = _boundAssetAmount(asset, assetAmount);
        pullAmount = _boundAssetAmount(asset, pullAmount);
        vm.assume(pullAmount <= assetAmount);
        IMockErc20(asset).mint(address(transferHelper), assetAmount);

        vm.prank(msgSender);
        transferHelper.transfer(asset, pullAmount, destination);

        assertEq(IMockErc20(asset).balanceOf(address(transferHelper)), transferHelper.getBalance(asset));
        assertEq(IMockErc20(asset).balanceOf(address(transferHelper)), assetAmount - pullAmount);
        assertEq(IMockErc20(asset).balanceOf(destination), pullAmount);
        if (destination != msgSender) {
            assertEq(IMockErc20(asset).balanceOf(msgSender), 0);
        }
    }

    function test_transfer_multipleErc20_singleDestination(
        address msgSenderFuzz,
        address destinationFuzz,
        bytes32 assetDeploymentSalt1,
        uint8 assetDecimals1,
        uint256 assetAmount1,
        uint256 pullAmount1,
        bytes32 assetDeploymentSalt2,
        uint8 assetDecimals2,
        uint256 assetAmount2,
        uint256 pullAmount2
    ) public {
        // Putting calldata params into memory to void stack too deep
        address destination = destinationFuzz;
        // Putting calldata params into memory to void stack too deep
        address msgSender = msgSenderFuzz;

        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(transferHelper));
        vm.assume(destination != address(0));
        vm.assume(destination != address(transferHelper));
        vm.assume(assetDeploymentSalt1 != assetDeploymentSalt2);

        address asset1 = _deployAssetWithSalt(assetDeploymentSalt1, assetDecimals1);
        assetAmount1 = _boundAssetAmount(asset1, assetAmount1);
        pullAmount1 = _boundAssetAmount(asset1, pullAmount1);
        vm.assume(pullAmount1 <= assetAmount1);
        IMockErc20(asset1).mint(address(transferHelper), assetAmount1);

        address asset2 = _deployAssetWithSalt(assetDeploymentSalt2, assetDecimals2);
        assetAmount2 = _boundAssetAmount(asset2, assetAmount2);
        pullAmount2 = _boundAssetAmount(asset2, pullAmount2);
        vm.assume(pullAmount2 <= assetAmount2);
        IMockErc20(asset2).mint(address(transferHelper), assetAmount2);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = pullAmount1;
        amounts[1] = pullAmount2;

        vm.prank(msgSender);
        transferHelper.transfer(assets, amounts, destination);

        assertEq(IMockErc20(asset1).balanceOf(address(transferHelper)), transferHelper.getBalance(asset1));
        assertEq(IMockErc20(asset1).balanceOf(address(transferHelper)), assetAmount1 - pullAmount1);
        assertEq(IMockErc20(asset1).balanceOf(destination), pullAmount1);
        if (destination != msgSender) {
            assertEq(IMockErc20(asset1).balanceOf(msgSender), 0);
        }

        assertEq(IMockErc20(asset2).balanceOf(address(transferHelper)), transferHelper.getBalance(asset2));
        assertEq(IMockErc20(asset2).balanceOf(address(transferHelper)), assetAmount2 - pullAmount2);
        assertEq(IMockErc20(asset2).balanceOf(destination), pullAmount2);
        if (destination != msgSender) {
            assertEq(IMockErc20(asset2).balanceOf(msgSender), 0);
        }
    }

    function test_transfer_multipleErc20_multipleDestinations(
        address msgSenderFuzz,
        address destination1Fuzz,
        address destination2Fuzz,
        bytes32 assetDeploymentSalt1,
        uint8 assetDecimals1,
        uint8 assetDecimals2,
        uint256 assetAmount1,
        uint256 pullAmount1,
        bytes32 assetDeploymentSalt2,
        uint256 assetAmount2,
        uint256 pullAmount2
    ) public {
        // Putting calldata params into memory to void stack too deep
        address destination1 = destination1Fuzz;
        // Putting calldata params into memory to void stack too deep
        address destination2 = destination2Fuzz;
        // Putting calldata params into memory to void stack too deep
        address msgSender = msgSenderFuzz;

        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(transferHelper));
        vm.assume(destination1 != address(0));
        vm.assume(destination1 != address(transferHelper));
        vm.assume(destination2 != address(0));
        vm.assume(destination2 != address(transferHelper));

        vm.assume(assetDeploymentSalt1 != assetDeploymentSalt2);

        address asset1 = _deployAssetWithSalt(assetDeploymentSalt1, assetDecimals1);
        assetAmount1 = _boundAssetAmount(asset1, assetAmount1);
        pullAmount1 = _boundAssetAmount(asset1, pullAmount1);
        vm.assume(pullAmount1 <= assetAmount1);
        IMockErc20(asset1).mint(address(transferHelper), assetAmount1);

        address asset2 = _deployAssetWithSalt(assetDeploymentSalt2, assetDecimals2);
        assetAmount2 = _boundAssetAmount(asset2, assetAmount2);
        pullAmount2 = _boundAssetAmount(asset2, pullAmount2);
        vm.assume(pullAmount2 <= assetAmount2);
        IMockErc20(asset2).mint(address(transferHelper), assetAmount2);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = pullAmount1;
        amounts[1] = pullAmount2;

        address[] memory destinations = new address[](2);
        destinations[0] = destination1;
        destinations[1] = destination2;

        vm.prank(msgSender);
        transferHelper.transfer(assets, amounts, destinations);

        assertEq(IMockErc20(asset1).balanceOf(address(transferHelper)), transferHelper.getBalance(asset1));
        assertEq(IMockErc20(asset1).balanceOf(address(transferHelper)), assetAmount1 - pullAmount1);
        assertEq(IMockErc20(asset1).balanceOf(destination1), pullAmount1);
        if (destination1 != msgSender) {
            assertEq(IMockErc20(asset1).balanceOf(msgSender), 0);
        }

        assertEq(IMockErc20(asset2).balanceOf(address(transferHelper)), transferHelper.getBalance(asset2));
        assertEq(IMockErc20(asset2).balanceOf(address(transferHelper)), assetAmount2 - pullAmount2);
        assertEq(IMockErc20(asset2).balanceOf(destination2), pullAmount2);
        if (destination2 != msgSender) {
            assertEq(IMockErc20(asset2).balanceOf(msgSender), 0);
        }
    }

    function test_transfer_reverts_nativeNotSupportedByRecipient(
        address msgSender,
        bytes32 destinationDeploymentSalt,
        uint256 nativeAmount,
        uint256 pullAmount
    ) public {
        address destination = address(new MockNonNativeRecipient{salt: destinationDeploymentSalt}());

        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(transferHelper));
        vm.assume(msgSender != destination);

        nativeAmount = _boundNativeAmount(nativeAmount);
        pullAmount = _boundNativeAmount(pullAmount);
        vm.assume(pullAmount <= nativeAmount);
        vm.deal(address(transferHelper), nativeAmount);

        vm.prank(msgSender);
        vm.expectRevert(abi.encodeWithSelector(Errors.NativeTransferFailed.selector));
        transferHelper.transfer(address(0), pullAmount, destination);
    }

    //////////////////////////////////////////////// HELPERS ///////////////////////////////////////////////////////////

    function _assumeCanReceiveNative(address recipient) internal {
        vm.deal(address(this), 1);
        (bool transferInSucceeded,) = payable(address(recipient)).call{value: 1}("");
        vm.prank(recipient);
        (bool transferOutSucceeded,) = payable(address(0)).call{value: 1}("");
        vm.assume(transferInSucceeded && transferOutSucceeded);
    }

    function _deployAssetWithSalt(bytes32 assetDeploymentSalt, uint8 assetDecimals) internal returns (address) {
        assetDecimals = _boundAssetDecimals(assetDecimals);
        if (uint256(assetDeploymentSalt) % 2 == 0) {
            return address(new MockErc20{salt: assetDeploymentSalt}("Test USD", "tUSD", assetDecimals));
        } else {
            return address(new MockNonStandardErc20{salt: assetDeploymentSalt}("Test USD", "tUSD", assetDecimals));
        }
    }
}
