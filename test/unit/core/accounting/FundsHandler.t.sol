// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IRescuableAssets} from "src/interfaces/IRescuableAssets.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAccountingChainGateway} from "test/mocks/MockAccountingChainGateway.sol";
import {MockAllocator} from "test/mocks/MockAllocator.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract FundsHandlerTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IMockErc20;

    address mockBbv;
    MockAccountingChainGateway mockGateway;
    MockAllocator mockAllocator;
    MockTransferHelper mockTransferHelper;
    MockAccessManager mockAccessManager;
    IMockErc20 mockAsset;

    FundsHandler fundsHandler;

    function _deployDefaultAsset() internal returns (IMockErc20) {
        return IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
    }

    function _deployFundsHandler(
        address bbv,
        address gateway,
        address allocator,
        address transferHelper,
        address accessManager
    ) internal returns (FundsHandler) {
        address fundsHandlerImpl = address(new FundsHandler(bbv, gateway, allocator, transferHelper));
        return FundsHandler(
            address(
                new TransparentUpgradeableProxy(
                    fundsHandlerImpl, address(this), abi.encodeCall(FundsHandler.initialize, (accessManager))
                )
            )
        );
    }

    function setUp() public {
        mockBbv = makeAddr("mockBbv");
        mockTransferHelper = new MockTransferHelper();
        mockGateway = new MockAccountingChainGateway(address(mockTransferHelper));
        mockAllocator = new MockAllocator();
        mockAccessManager = new MockAccessManager(makeAddr("admin"));
        mockAsset = IMockErc20(address(new MockNonStandardErc20("Test USD", "tUSD", 6)));
        fundsHandler = _deployFundsHandler(
            mockBbv,
            address(mockGateway),
            address(mockAllocator),
            address(mockTransferHelper),
            address(mockAccessManager)
        );
        mockAllocator.mockTransferHelper(address(mockTransferHelper));
    }

    function test_getAggregatedBalance_returnsExpectedAggregatedBalance(
        uint256 accChainBalance1,
        uint256 accChainBalance2,
        uint256 accChainBalance3,
        uint256 earnChainBalance1Ray,
        uint256 earnChainBalance2Ray,
        uint256 earnChainBalance3Ray
    ) public {
        IMockErc20 mockAsset1 = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        IMockErc20 mockAsset2 = IMockErc20(address(new MockErc20("Test GHO", "tGHO", 18)));
        IMockErc20 mockAsset3 = IMockErc20(address(new MockNonStandardErc20("Test USDC", "tUSDC", 6)));

        accChainBalance1 = _boundAssetAmountAllowingZero(address(mockAsset1), accChainBalance1);
        accChainBalance2 = _boundAssetAmountAllowingZero(address(mockAsset2), accChainBalance2);
        accChainBalance3 = _boundAssetAmountAllowingZero(address(mockAsset3), accChainBalance3);

        mockAllocator.mockAssetBalance(address(mockAsset1), accChainBalance1);
        mockAllocator.mockAssetBalance(address(mockAsset2), accChainBalance2);
        mockAllocator.mockAssetBalance(address(mockAsset3), accChainBalance3);

        uint256 accChainBalanceRay = accChainBalance1.assetDecimalsToRay(address(mockAsset1))
            + accChainBalance2.assetDecimalsToRay(address(mockAsset2))
            + accChainBalance3.assetDecimalsToRay(address(mockAsset3));

        earnChainBalance1Ray = _boundRayAmountAllowingZero(earnChainBalance1Ray);
        earnChainBalance2Ray = _boundRayAmountAllowingZero(earnChainBalance2Ray);
        earnChainBalance3Ray = _boundRayAmountAllowingZero(earnChainBalance3Ray);

        vm.startPrank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(block.chainid + 1, earnChainBalance1Ray, 1);
        fundsHandler.updateChainBalanceCallback(block.chainid + 2, earnChainBalance2Ray, 1);
        fundsHandler.updateChainBalanceCallback(block.chainid + 3, earnChainBalance3Ray, 1);
        vm.stopPrank();

        uint256 expectedAggregatedBalance =
            accChainBalanceRay + earnChainBalance1Ray + earnChainBalance2Ray + earnChainBalance3Ray;

        assertEq(fundsHandler.getAggregatedBalance(), expectedAggregatedBalance);
    }

    function test_getAssetBalances_returnsExpectedAssetBalances(
        uint256 accChainBalance1,
        uint256 accChainBalance2,
        uint256 accChainBalance3,
        uint256 earnChainBalance1Ray,
        uint256 earnChainBalance2Ray,
        uint256 earnChainBalance3Ray
    ) public {
        IFundsHandler.AssetBalance[] memory expectedAssetBalances = new IFundsHandler.AssetBalance[](6);

        IMockErc20 mockAsset1 = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        IMockErc20 mockAsset2 = IMockErc20(address(new MockErc20("Test GHO", "tGHO", 18)));
        IMockErc20 mockAsset3 = IMockErc20(address(new MockNonStandardErc20("Test USDC", "tUSDC", 6)));

        accChainBalance1 = _boundAssetAmountAllowingZero(address(mockAsset1), accChainBalance1);
        mockAllocator.mockAssetBalance(address(mockAsset1), accChainBalance1);
        accChainBalance2 = _boundAssetAmountAllowingZero(address(mockAsset2), accChainBalance2);
        mockAllocator.mockAssetBalance(address(mockAsset2), accChainBalance2);
        accChainBalance3 = _boundAssetAmountAllowingZero(address(mockAsset3), accChainBalance3);
        mockAllocator.mockAssetBalance(address(mockAsset3), accChainBalance3);

        // Filling these three here and the rest after because otherwise it gives stack too deep error.
        expectedAssetBalances[0] = IFundsHandler.AssetBalance({
            asset: address(mockAsset1),
            amountRay: accChainBalance1.assetDecimalsToRay(address(mockAsset1)),
            chainId: block.chainid
        });
        expectedAssetBalances[1] = IFundsHandler.AssetBalance({
            asset: address(mockAsset2),
            amountRay: accChainBalance2.assetDecimalsToRay(address(mockAsset2)),
            chainId: block.chainid
        });
        expectedAssetBalances[2] = IFundsHandler.AssetBalance({
            asset: address(mockAsset3),
            amountRay: accChainBalance3.assetDecimalsToRay(address(mockAsset3)),
            chainId: block.chainid
        });

        earnChainBalance1Ray = _boundRayAmountAllowingZero(earnChainBalance1Ray);
        earnChainBalance2Ray = _boundRayAmountAllowingZero(earnChainBalance2Ray);
        earnChainBalance3Ray = _boundRayAmountAllowingZero(earnChainBalance3Ray);

        uint256 earnChainId1 = block.chainid + 1;
        uint256 earnChainId2 = block.chainid + 2;
        uint256 earnChainId3 = block.chainid + 3;

        vm.startPrank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(earnChainId1, earnChainBalance1Ray, 1);
        fundsHandler.updateChainBalanceCallback(earnChainId2, earnChainBalance2Ray, 1);
        fundsHandler.updateChainBalanceCallback(earnChainId3, earnChainBalance3Ray, 1);
        vm.stopPrank();

        expectedAssetBalances[3] =
            IFundsHandler.AssetBalance({asset: address(0), amountRay: earnChainBalance1Ray, chainId: earnChainId1});
        expectedAssetBalances[4] =
            IFundsHandler.AssetBalance({asset: address(0), amountRay: earnChainBalance2Ray, chainId: earnChainId2});
        expectedAssetBalances[5] =
            IFundsHandler.AssetBalance({asset: address(0), amountRay: earnChainBalance3Ray, chainId: earnChainId3});

        IFundsHandler.AssetBalance[] memory actualAssetBalances = fundsHandler.getAssetBalances();
        assertEq(actualAssetBalances.length, expectedAssetBalances.length);
        for (uint256 i = 0; i < actualAssetBalances.length; i++) {
            assertEq(actualAssetBalances[i].asset, expectedAssetBalances[i].asset);
            assertEq(actualAssetBalances[i].amountRay, expectedAssetBalances[i].amountRay);
            assertEq(actualAssetBalances[i].chainId, expectedAssetBalances[i].chainId);
        }
    }

    function test_processDeposit_pushesFundsToAllocator(
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmountAllowingZero(asset, amount);

        vm.expectCall(address(mockAllocator), abi.encodeWithSelector(IAllocator.deposit.selector, asset, amount));

        vm.prank(address(mockBbv));
        fundsHandler.processDeposit(asset, amount);
    }

    function test_processDeposit_reverts_ifMsgSenderIsNotTheBBV(
        address msgSender,
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        _assumeNotProxyAdmin(msgSender, address(fundsHandler));
        vm.assume(msgSender != address(mockBbv));

        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);

        amount = _boundAssetAmountAllowingZero(address(asset), amount);

        vm.expectRevert(IFundsHandler.OnlyBasedBoostedVault.selector);
        vm.prank(msgSender);
        fundsHandler.processDeposit(asset, amount);
    }

    function test_processWithdrawal_pullFundsFromAllocator(
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmountAllowingZero(address(asset), amount);

        vm.expectCall(address(mockAllocator), abi.encodeWithSelector(IAllocator.withdraw.selector, asset, amount));

        vm.prank(address(mockBbv));
        fundsHandler.processWithdrawal(asset, amount);
    }

    function test_processWithdrawal_reverts_ifMsgSenderIsNotTheBBV(
        address msgSender,
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        _assumeNotProxyAdmin(msgSender, address(fundsHandler));
        vm.assume(msgSender != address(mockBbv));

        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmountAllowingZero(address(asset), amount);

        vm.expectRevert(IFundsHandler.OnlyBasedBoostedVault.selector);
        vm.prank(msgSender);
        fundsHandler.processWithdrawal(asset, amount);
    }

    function test_fundsArrivedFromChainCallback_reverts_ifMsgSenderIsNotTheGateway(
        address msgSender,
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        _assumeNotProxyAdmin(msgSender, address(fundsHandler));
        vm.assume(msgSender != address(mockGateway));

        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmountAllowingZero(address(asset), amount);

        vm.expectRevert(ErrorsLib.OnlyGateway.selector);
        vm.prank(msgSender);
        fundsHandler.fundsArrivedFromChainCallback(asset, amount);
    }

    function test_fundsArrivedFromChainCallback_pushesFundsToAllocator(
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmountAllowingZero(address(asset), amount);

        vm.expectCall(address(mockAllocator), abi.encodeWithSelector(IAllocator.deposit.selector, asset, amount));

        vm.prank(address(mockGateway));
        fundsHandler.fundsArrivedFromChainCallback(asset, amount);
    }

    function test_updateChainBalanceCallback_reverts_ifMsgSenderIsNotTheGateway(
        address msgSender,
        uint256 chainId,
        uint256 snapshotBalanceRay,
        uint256 chainBalanceSnapshotNonce
    ) public {
        _assumeNotProxyAdmin(msgSender, address(fundsHandler));
        vm.assume(msgSender != address(mockGateway));
        vm.assume(chainId != block.chainid);

        snapshotBalanceRay = _boundRayAmountAllowingZero(snapshotBalanceRay);

        vm.expectRevert(ErrorsLib.OnlyGateway.selector);
        vm.prank(msgSender);
        fundsHandler.updateChainBalanceCallback(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);
    }

    function test_updateChainBalanceCallback_updatesChainBalance(
        uint256 chainId,
        uint256 snapshotBalanceRay,
        uint256 chainBalanceSnapshotNonce
    ) public {
        vm.assume(chainId != block.chainid);
        snapshotBalanceRay = _boundRayAmountAllowingZero(snapshotBalanceRay);
        vm.assume(chainBalanceSnapshotNonce > 0);

        assertEq(fundsHandler.getAssetBalances().length, 0);

        vm.expectEmit(true, true, true, true);
        emit IFundsHandler.ChainBalanceSnapshotReceived(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);
        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, snapshotBalanceRay);
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);
    }

    function test_decrementChainBalanceSnapshotCallback_reverts_ifMsgSenderIsNotTheGateway(
        address msgSender,
        uint256 amountToDecrementRay
    ) public {
        uint256 chainId = 1;
        _assumeNotProxyAdmin(msgSender, address(fundsHandler));
        vm.assume(msgSender != address(mockGateway));

        amountToDecrementRay = _boundRayAmount(amountToDecrementRay);

        vm.expectRevert(ErrorsLib.OnlyGateway.selector);
        vm.prank(msgSender);
        fundsHandler.decrementChainBalanceSnapshotCallback(chainId, amountToDecrementRay);
    }

    function test_decrementChainBalanceSnapshotCallback_decrementsChainBalance(
        uint256 chainId,
        uint256 currentSnapshotBalanceRay,
        uint256 amountToDecrementRay
    ) public {
        vm.assume(chainId != block.chainid);
        currentSnapshotBalanceRay = _boundRayAmountAllowingZero(currentSnapshotBalanceRay);
        amountToDecrementRay = _boundRayAmount(amountToDecrementRay);

        assertEq(fundsHandler.getAssetBalances().length, 0);

        // First use the update chain balance callback to set the snapshot balance
        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, currentSnapshotBalanceRay, 0);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, currentSnapshotBalanceRay);
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);

        // Then use the decrement chain balance snapshot callback to decrement the snapshot balance
        vm.expectEmit(true, true, true, true);
        emit IFundsHandler.ChainBalanceSnapshotDecremented(chainId, amountToDecrementRay);
        vm.prank(address(mockGateway));
        fundsHandler.decrementChainBalanceSnapshotCallback(chainId, amountToDecrementRay);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        if (currentSnapshotBalanceRay >= amountToDecrementRay) {
            assertEq(fundsHandler.getAssetBalances()[0].amountRay, currentSnapshotBalanceRay - amountToDecrementRay);
        } else {
            assertEq(fundsHandler.getAssetBalances()[0].amountRay, 0);
        }
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);
    }

    function test_decrementChainBalanceSnapshotCallback_decrementsChainBalance_currentSnapshotDoesNotExist(
        uint256 chainId,
        uint256 amountToDecrementRay
    ) public {
        // Context: check that the event ChainBalanceSnapshotDecremented is not emitted.
        vm.assume(chainId != block.chainid);
        amountToDecrementRay = _boundRayAmount(amountToDecrementRay);

        assertEq(fundsHandler.getAssetBalances().length, 0);

        vm.recordLogs();
        vm.prank(address(mockGateway));
        fundsHandler.decrementChainBalanceSnapshotCallback(chainId, amountToDecrementRay);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);

        assertEq(fundsHandler.getAssetBalances().length, 0);
    }

    function test_updateChainBalanceCallback_updatesChainBalanceIfChainSendsBalanceSnapshotForFirstTimeRegardlessOfNonce(
        uint256 chainId,
        uint256 snapshotBalanceRay,
        uint256 chainBalanceSnapshotNonce
    ) public {
        vm.assume(chainId != block.chainid);
        snapshotBalanceRay = _boundRayAmountAllowingZero(snapshotBalanceRay);

        assertEq(fundsHandler.getAssetBalances().length, 0);

        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, snapshotBalanceRay);
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);
    }

    function test_updateChainBalanceCallback_doesNotUpdateChainBalanceIfNonceIsTheSameAsCurrentNonce(
        uint256 chainId,
        uint256 snapshotBalanceRay,
        uint256 secondSnapshotBalanceRay,
        uint256 chainBalanceSnapshotNonce
    ) public {
        vm.assume(chainId != block.chainid);
        snapshotBalanceRay = _boundRayAmountAllowingZero(snapshotBalanceRay);
        secondSnapshotBalanceRay = _boundRayAmountAllowingZero(secondSnapshotBalanceRay);
        vm.assume(secondSnapshotBalanceRay != snapshotBalanceRay);

        assertEq(fundsHandler.getAssetBalances().length, 0);

        // First snapshot balance update
        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, snapshotBalanceRay);
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);

        // Second snapshot balance update for the same chain and nonce
        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, secondSnapshotBalanceRay, chainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, snapshotBalanceRay); // It was not updated!
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);
    }

    function test_updateChainBalanceCallback_doesNotUpdateChainBalanceIfNonceIsSmallerThanCurrentNonce(
        uint256 chainId,
        uint256 snapshotBalanceRay,
        uint256 chainBalanceSnapshotNonce,
        uint256 secondSnapshotBalanceRay,
        uint256 secondChainBalanceSnapshotNonce
    ) public {
        vm.assume(chainId != block.chainid);
        snapshotBalanceRay = _boundRayAmountAllowingZero(snapshotBalanceRay);
        secondSnapshotBalanceRay = _boundRayAmountAllowingZero(secondSnapshotBalanceRay);
        vm.assume(secondSnapshotBalanceRay != snapshotBalanceRay);
        vm.assume(secondChainBalanceSnapshotNonce < chainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 0);

        // First snapshot balance update
        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, snapshotBalanceRay);
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);

        // Second snapshot balance update for the same chain, with smaller nonce
        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, secondSnapshotBalanceRay, secondChainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, snapshotBalanceRay); // It was not updated!
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);
    }

    function test_updateChainBalanceCallback_updatesChainBalanceIfNonceIsGreaterThanCurrentNonce(
        uint256 chainId,
        uint256 snapshotBalanceRay,
        uint256 chainBalanceSnapshotNonce,
        uint256 secondSnapshotBalanceRay,
        uint256 secondChainBalanceSnapshotNonce
    ) public {
        vm.assume(chainId != block.chainid);
        snapshotBalanceRay = _boundRayAmountAllowingZero(snapshotBalanceRay);
        secondSnapshotBalanceRay = _boundRayAmountAllowingZero(secondSnapshotBalanceRay);
        vm.assume(secondSnapshotBalanceRay != snapshotBalanceRay);
        vm.assume(secondChainBalanceSnapshotNonce > chainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 0);

        // First snapshot balance update
        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, snapshotBalanceRay);
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);

        // Second snapshot balance update for the same chain, with bigger nonce
        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, secondSnapshotBalanceRay, secondChainBalanceSnapshotNonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, secondSnapshotBalanceRay); // It was updated!
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);
    }

    function test_rescueTokens_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 fhAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(fundsHandler));

        fhAssetBalance = _boundAssetAmount(address(mockAsset), fhAssetBalance);
        assetAmountToRescue = _boundAssetAmount(address(mockAsset), assetAmountToRescue);
        vm.assume(fhAssetBalance >= assetAmountToRescue);
        mockAsset.mint(address(fundsHandler), fhAssetBalance);

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(fundsHandler), IRescuableAssets.rescueTokens.selector
        );
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableAssets(address(fundsHandler)).rescueTokens(address(mockAsset), assetAmountToRescue);
    }

    function test_rescueTokens_getsExpectedAmountOfAssetsToMsgSender(
        address msgSender,
        uint256 fhAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        vm.assume(msgSender != address(0));
        _assumeNotProxyAdmin(msgSender, address(fundsHandler));

        fhAssetBalance = _boundAssetAmount(address(mockAsset), fhAssetBalance);
        assetAmountToRescue = _boundAssetAmount(address(mockAsset), assetAmountToRescue);
        vm.assume(fhAssetBalance >= assetAmountToRescue);
        mockAsset.mint(address(fundsHandler), fhAssetBalance);
        assertEq(mockAsset.balanceOf(address(fundsHandler)), fhAssetBalance);
        vm.assume(mockAsset.balanceOf(msgSender) == 0);

        vm.prank(msgSender);
        IRescuableAssets(address(fundsHandler)).rescueTokens(address(mockAsset), assetAmountToRescue);

        assertEq(mockAsset.balanceOf(msgSender), assetAmountToRescue);
        assertEq(mockAsset.balanceOf(address(fundsHandler)), fhAssetBalance - assetAmountToRescue);
    }

    function test_pushFundsToChain_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        address asset,
        uint256 amount,
        uint256 chainId,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        bridgeParams_feeAmount = _boundNativeAmount(bridgeParams_feeAmount);
        vm.deal(address(unauthorizedMsgSender), bridgeParams_feeAmount);
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(unauthorizedMsgSender),
            feeToken: address(0),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        vm.assume(chainId != block.chainid);

        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(fundsHandler));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(fundsHandler), IFundsHandler.pushFundsToChain.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        fundsHandler.pushFundsToChain(asset, amount, chainId, bridgeParams);
    }

    function test_pushFundsToChain_reverts_ifTransferHelperBalanceIsNotFullyConsumed_bridgeParamNativeFee(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        amount = _boundAssetAmount(address(mockAsset), amount);
        mockAsset.mint(address(this), amount);
        mockAsset.forceApprove(address(fundsHandler), amount);
        bridgeParams_feeAmount = _boundNativeAmount(bridgeParams_feeAmount);
        vm.deal(address(this), bridgeParams_feeAmount);
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(0),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        vm.expectRevert(
            abi.encodeWithSelector(TransferHelperClient.TransferHelperBalanceNotConsumed.selector, address(0))
        );
        fundsHandler.pushFundsToChain{value: bridgeParams_feeAmount}(address(mockAsset), amount, chainId, bridgeParams);
    }

    function test_pushFundsToChain_reverts_ifTransferHelperBalanceIsNotFullyConsumed_bridgeParamTokenFee(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeParams_feeAmount = _boundAssetAmount(address(mockAsset), bridgeParams_feeAmount);
        mockAsset.mint(address(this), bridgeParams_feeAmount);
        mockAsset.forceApprove(address(fundsHandler), bridgeParams_feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(mockAsset),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        // Consumes amount but not the fee token
        mockGateway.mockToConsumeAssetFromTransferHelperInNextCall(address(mockAsset), amount);

        vm.expectRevert(
            abi.encodeWithSelector(TransferHelperClient.TransferHelperBalanceNotConsumed.selector, address(mockAsset))
        );
        fundsHandler.pushFundsToChain(address(mockAsset), amount, chainId, bridgeParams);
    }

    function test_pushFundsToChain_reverts_ifAmountIsZero(
        uint256 chainId,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);

        bridgeParams_feeAmount = _boundNativeAmount(bridgeParams_feeAmount);
        vm.deal(address(this), bridgeParams_feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(0),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ZeroAmount.selector));
        fundsHandler.pushFundsToChain{value: bridgeParams_feeAmount}(address(mockAsset), 0, chainId, bridgeParams);
    }

    function test_pushFundsToChain_reverts_ifTransferHelperBalanceIsNotFullyConsumed_amountAssetSameAsFeeToken(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeParams_feeAmount = _boundAssetAmount(address(mockAsset), bridgeParams_feeAmount);
        mockAsset.mint(address(this), bridgeParams_feeAmount);
        mockAsset.forceApprove(address(fundsHandler), bridgeParams_feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(mockAsset),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        // Consumes fee but not amount
        mockGateway.mockToConsumeAssetFromTransferHelperInNextCall(address(mockAsset), bridgeParams_feeAmount);

        vm.expectRevert(
            abi.encodeWithSelector(TransferHelperClient.TransferHelperBalanceNotConsumed.selector, address(mockAsset))
        );
        fundsHandler.pushFundsToChain(address(mockAsset), amount, chainId, bridgeParams);
    }

    function test_pushFundsToChain_reverts_ifTransferHelperBalanceIsNotFullyConsumed_amountAssetDiffThanFeeToken(
        uint256 amount,
        uint256 chainId,
        bytes32 feeTokenSalt,
        uint8 feeTokenDecimals,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        address feeToken = _deployAssetWithSalt(feeTokenSalt, feeTokenDecimals);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeParams_feeAmount = _boundAssetAmount(feeToken, bridgeParams_feeAmount);
        IMockErc20(feeToken).mint(address(this), bridgeParams_feeAmount);
        IMockErc20(feeToken).forceApprove(address(fundsHandler), bridgeParams_feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: feeToken,
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        // Consumes fee but not amount
        mockGateway.mockToConsumeAssetFromTransferHelperInNextCall(address(feeToken), bridgeParams_feeAmount);

        vm.expectRevert(
            abi.encodeWithSelector(TransferHelperClient.TransferHelperBalanceNotConsumed.selector, address(mockAsset))
        );
        fundsHandler.pushFundsToChain(address(mockAsset), amount, chainId, bridgeParams);
    }

    function test_pushFundsToChain_reverts_ifBridgeFeePayerIsNotTheCaller(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeParams_feeAmount = _boundAssetAmount(address(mockAsset), bridgeParams_feeAmount);
        mockAsset.mint(address(this), bridgeParams_feeAmount);
        mockAsset.forceApprove(address(fundsHandler), bridgeParams_feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: makeAddr("unauthorizedFeePayer"),
            feeToken: address(mockAsset),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        mockGateway.mockToConsumeAssetFromTransferHelperInNextCall(address(mockAsset), bridgeParams_feeAmount + amount);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidBridgeFeePayer.selector));
        fundsHandler.pushFundsToChain(address(mockAsset), amount, chainId, bridgeParams);
    }

    function test_pushFundsToChain_callsGatewaySendPushFundsMessage(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeParams_feeAmount = _boundAssetAmount(address(mockAsset), bridgeParams_feeAmount);
        mockAsset.mint(address(this), bridgeParams_feeAmount);
        mockAsset.forceApprove(address(fundsHandler), bridgeParams_feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(mockAsset),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        mockGateway.mockToConsumeAssetFromTransferHelperInNextCall(address(mockAsset), bridgeParams_feeAmount + amount);

        vm.expectEmit(true, true, true, true);
        emit IFundsHandler.ChainBalanceSnapshotIncremented(chainId, amount.assetDecimalsToRay(address(mockAsset)));
        vm.expectCall(
            address(mockGateway),
            abi.encodeCall(
                MockAccountingChainGateway.sendPushFundsToChainMessage,
                (address(mockAsset), amount, chainId, bridgeParams)
            )
        );
        fundsHandler.pushFundsToChain(address(mockAsset), amount, chainId, bridgeParams);
    }

    function test_pushFundsToChain_createsBalanceSnapshotIfChainWasNotPreviouslyUsed(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeParams_feeAmount = _boundAssetAmount(address(mockAsset), bridgeParams_feeAmount);
        mockAsset.mint(address(this), bridgeParams_feeAmount);
        mockAsset.forceApprove(address(fundsHandler), bridgeParams_feeAmount);

        assertEq(fundsHandler.getAssetBalances().length, 0);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(mockAsset),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        mockGateway.mockToConsumeAssetFromTransferHelperInNextCall(address(mockAsset), bridgeParams_feeAmount + amount);

        fundsHandler.pushFundsToChain(address(mockAsset), amount, chainId, bridgeParams);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, amount.assetDecimalsToRay(address(mockAsset)));
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);
    }

    function test_pushFundsToChain_createsBalanceSnapshotIncrementingExistingChainBalance(
        uint256 amount,
        uint256 chainId,
        uint256 currentChainBalanceRay,
        uint256 nonce,
        uint256 bridgeParams_feeAmount,
        uint256 bridgeParams_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        currentChainBalanceRay = _boundRayAmountAllowingZero(currentChainBalanceRay);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeParams_feeAmount = _boundAssetAmount(address(mockAsset), bridgeParams_feeAmount);
        mockAsset.mint(address(this), bridgeParams_feeAmount);
        mockAsset.forceApprove(address(fundsHandler), bridgeParams_feeAmount);

        vm.prank(address(mockGateway));
        fundsHandler.updateChainBalanceCallback(chainId, currentChainBalanceRay, nonce);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(fundsHandler.getAssetBalances()[0].amountRay, currentChainBalanceRay);
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(mockAsset),
            feeAmount: bridgeParams_feeAmount,
            feeRefundThreshold: 0,
            gasLimit: bridgeParams_gasLimit,
            data: ""
        });

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        mockGateway.mockToConsumeAssetFromTransferHelperInNextCall(address(mockAsset), bridgeParams_feeAmount + amount);

        fundsHandler.pushFundsToChain(address(mockAsset), amount, chainId, bridgeParams);

        assertEq(fundsHandler.getAssetBalances().length, 1);
        assertEq(fundsHandler.getAssetBalances()[0].asset, address(0));
        assertEq(
            fundsHandler.getAssetBalances()[0].amountRay,
            currentChainBalanceRay + amount.assetDecimalsToRay(address(mockAsset))
        );
        assertEq(fundsHandler.getAssetBalances()[0].chainId, chainId);
    }

    //////////////////////////////////////////////// HELPERS ///////////////////////////////////////////////////////////

    function _deployAssetWithSalt(bytes32 assetDeploymentSalt, uint8 assetDecimals) internal returns (address) {
        assetDecimals = _boundAssetDecimals(assetDecimals);
        return address(new MockNonStandardErc20{salt: assetDeploymentSalt}("Test USD", "tUSD", assetDecimals));
    }
}
