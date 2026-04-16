// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Constants} from "src/types/Constants.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {IMockErc20, MockErc20} from "test/mocks/MockErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";
import {MockTransferHelperClient} from "test/mocks/MockTransferHelperClient.sol";

contract TransferHelperClientTest is TestWithHelpers {
    MockTransferHelper transferHelper;
    MockTransferHelperClient client;
    IMockErc20 tokenA;
    IMockErc20 tokenB;

    uint256 constant INITIAL_TOKEN_BALANCE = 1_000e18;
    uint256 constant INITIAL_NATIVE_BALANCE = 10 ether;

    function setUp() public {
        transferHelper = new MockTransferHelper();
        client = new MockTransferHelperClient(address(transferHelper));
        tokenA = IMockErc20(address(new MockErc20("Token A", "TKA", 18)));
        tokenB = IMockErc20(address(new MockErc20("Token B", "TKB", 6)));

        // Seed the TransferHelper with initial balances.
        tokenA.mint(address(transferHelper), INITIAL_TOKEN_BALANCE);
        tokenB.mint(address(transferHelper), INITIAL_TOKEN_BALANCE);
        vm.deal(address(transferHelper), INITIAL_NATIVE_BALANCE);

        // Fund the harness so it can simulate pushes of native currency back into the TransferHelper.
        vm.deal(address(client), 100 ether);
    }

    // ---------------------------------------------------------------------
    // Single-asset modifier
    // ---------------------------------------------------------------------

    function test_singleAsset_erc20_unchanged_succeeds() public {
        client.exerciseSingleAsset(address(tokenA));
    }

    function test_singleAsset_erc20_decrease_succeeds() public {
        client.consumeSingleAsset(address(tokenA), INITIAL_TOKEN_BALANCE / 4);
        assertEq(tokenA.balanceOf(address(transferHelper)), INITIAL_TOKEN_BALANCE - INITIAL_TOKEN_BALANCE / 4);
    }

    function test_singleAsset_erc20_increase_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(TransferHelperClient.TransferHelperBalanceNotConsumed.selector, address(tokenA))
        );
        client.increaseSingleAsset(address(tokenA), 1);
    }

    function test_singleAsset_native_unchanged_succeeds() public {
        client.exerciseSingleAsset(Constants.NATIVE_CURRENCY);
    }

    function test_singleAsset_native_decrease_succeeds() public {
        client.consumeSingleAsset(Constants.NATIVE_CURRENCY, 3 ether);
        assertEq(address(transferHelper).balance, INITIAL_NATIVE_BALANCE - 3 ether);
    }

    function test_singleAsset_native_increase_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                TransferHelperClient.TransferHelperBalanceNotConsumed.selector, Constants.NATIVE_CURRENCY
            )
        );
        client.increaseSingleAsset(Constants.NATIVE_CURRENCY, 1);
    }

    // ---------------------------------------------------------------------
    // Multi-asset modifier
    // ---------------------------------------------------------------------

    function test_multiAsset_empty_succeeds() public {
        address[] memory assets = new address[](0);
        client.exerciseMultiAsset(assets);
    }

    function test_multiAsset_erc20Only_unchanged_succeeds() public {
        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        client.exerciseMultiAsset(assets);
    }

    function test_multiAsset_erc20Only_decrease_succeeds() public {
        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e18;
        amounts[1] = 20e18;

        client.consumeMultiAsset(assets, amounts);

        assertEq(tokenA.balanceOf(address(transferHelper)), INITIAL_TOKEN_BALANCE - 10e18);
        assertEq(tokenB.balanceOf(address(transferHelper)), INITIAL_TOKEN_BALANCE - 20e18);
    }

    function test_multiAsset_erc20Only_increaseOne_reverts() public {
        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 1;

        vm.expectRevert(
            abi.encodeWithSelector(TransferHelperClient.TransferHelperBalanceNotConsumed.selector, address(tokenB))
        );
        client.increaseMultiAsset(assets, amounts);
    }

    function test_multiAsset_withNativeCurrency_succeeds() public {
        address[] memory assets = new address[](3);
        assets[0] = address(tokenA);
        assets[1] = Constants.NATIVE_CURRENCY;
        assets[2] = address(tokenB);

        client.exerciseMultiAsset(assets);
    }

    function test_multiAsset_withNativeCurrency_onlyNative_succeeds() public {
        address[] memory assets = new address[](1);
        assets[0] = Constants.NATIVE_CURRENCY;

        client.exerciseMultiAsset(assets);
    }

    function test_multiAsset_withNativeCurrency_decrease_succeeds() public {
        address[] memory assets = new address[](3);
        assets[0] = address(tokenA);
        assets[1] = Constants.NATIVE_CURRENCY;
        assets[2] = address(tokenB);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5e18;
        amounts[1] = 2 ether;
        amounts[2] = 7e18;

        client.consumeMultiAsset(assets, amounts);

        assertEq(tokenA.balanceOf(address(transferHelper)), INITIAL_TOKEN_BALANCE - 5e18);
        assertEq(address(transferHelper).balance, INITIAL_NATIVE_BALANCE - 2 ether);
        assertEq(tokenB.balanceOf(address(transferHelper)), INITIAL_TOKEN_BALANCE - 7e18);
    }

    function test_multiAsset_withNativeCurrency_nativeIncrease_reverts() public {
        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = Constants.NATIVE_CURRENCY;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                TransferHelperClient.TransferHelperBalanceNotConsumed.selector, Constants.NATIVE_CURRENCY
            )
        );
        client.increaseMultiAsset(assets, amounts);
    }
}
