// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {PolicyRegistry} from "src/periphery/PolicyRegistry.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAccountingChainGateway} from "test/mocks/MockAccountingChainGateway.sol";
import {MockAllocator} from "test/mocks/MockAllocator.sol";
import {MockBridgeAdapter} from "test/mocks/MockBridgeAdapter.sol";
import {MockChainBalanceOracle} from "test/mocks/MockChainBalanceOracle.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract FundsHandlerTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IMockErc20;

    address ADMIN;

    address mockStableVault;
    MockAccountingChainGateway mockGateway;
    MockBridgeAdapter mockBridgeAdapter;
    MockAllocator mockAllocator;
    PriceOracle priceOracle;
    MockChainBalanceOracle mockChainBalanceOracle;
    MockTransferHelper mockTransferHelper;
    MockAccessManager mockAccessManager;
    PolicyRegistry policyRegistry;
    IMockErc20 mockAsset;

    FundsHandler fundsHandler;

    function _deployDefaultAsset() internal returns (IMockErc20) {
        return IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
    }

    function _deployFundsHandler(
        address stableVault,
        address gateway,
        address allocator,
        address priceOracleAddr,
        address transferHelper,
        address chainBalanceOracle,
        address accessManager,
        address policyRegistryAddress
    ) internal returns (FundsHandler) {
        address fundsHandlerImpl = address(
            new FundsHandler(
                stableVault,
                gateway,
                allocator,
                priceOracleAddr,
                transferHelper,
                chainBalanceOracle,
                policyRegistryAddress
            )
        );
        return FundsHandler(
            address(
                new TransparentUpgradeableProxy(
                    fundsHandlerImpl, address(this), abi.encodeCall(FundsHandler.initialize, (accessManager))
                )
            )
        );
    }

    function setUp() public {
        // Warp to a reasonable timestamp to avoid underflow.
        vm.warp(block.timestamp + 1 days);
        ADMIN = makeAddr("admin");
        mockStableVault = makeAddr("mockStableVault");
        mockTransferHelper = new MockTransferHelper();
        mockGateway = new MockAccountingChainGateway(address(mockTransferHelper));
        mockBridgeAdapter = new MockBridgeAdapter(address(mockTransferHelper));
        mockAllocator = new MockAllocator();
        mockAccessManager = new MockAccessManager(ADMIN);
        policyRegistry = new PolicyRegistry(address(mockAccessManager));
        priceOracle = _deployPriceOracle(address(mockAccessManager), 9_995e23);
        mockChainBalanceOracle = new MockChainBalanceOracle();
        mockAsset = IMockErc20(address(new MockNonStandardErc20("Test USD", "tUSD", 6)));
        fundsHandler = _deployFundsHandler(
            mockStableVault,
            address(mockGateway),
            address(mockAllocator),
            address(priceOracle),
            address(mockTransferHelper),
            address(mockChainBalanceOracle),
            address(mockAccessManager),
            address(policyRegistry)
        );
        mockAllocator.mockTransferHelper(address(mockTransferHelper));
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        new FundsHandler(
            mockStableVault,
            address(mockGateway),
            address(mockAllocator),
            address(priceOracle),
            address(0),
            address(mockChainBalanceOracle),
            address(policyRegistry)
        );
    }

    function test_getAggregatedBalance_returnsExpectedAggregatedBalance(
        uint256 accChainBalance1,
        uint256 accChainBalance2,
        uint256 accChainBalance3
    ) public {
        IMockErc20 mockAsset1 = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        IMockErc20 mockAsset2 = IMockErc20(address(new MockErc20("Test GHO", "tGHO", 18)));
        IMockErc20 mockAsset3 = IMockErc20(address(new MockNonStandardErc20("Test USDC", "tUSDC", 6)));

        // Set mock prices (1 RAY = 1:1 price ratio for simplicity)
        _mockAssetPrice(address(priceOracle), address(mockAsset1), MathLib.RAY);
        _mockAssetPrice(address(priceOracle), address(mockAsset2), MathLib.RAY);
        _mockAssetPrice(address(priceOracle), address(mockAsset3), MathLib.RAY);

        accChainBalance1 = _boundAssetAmountAllowingZero(address(mockAsset1), accChainBalance1);
        accChainBalance2 = _boundAssetAmountAllowingZero(address(mockAsset2), accChainBalance2);
        accChainBalance3 = _boundAssetAmountAllowingZero(address(mockAsset3), accChainBalance3);

        mockAllocator.mockAssetBalance(address(mockAsset1), accChainBalance1);
        mockAllocator.mockAssetBalance(address(mockAsset2), accChainBalance2);
        mockAllocator.mockAssetBalance(address(mockAsset3), accChainBalance3);

        uint256 expectedAggregatedBalance = accChainBalance1.assetDecimalsToRay(address(mockAsset1))
            + accChainBalance2.assetDecimalsToRay(address(mockAsset2))
            + accChainBalance3.assetDecimalsToRay(address(mockAsset3));

        assertEq(fundsHandler.getAggregatedBalance(), expectedAggregatedBalance);
    }

    function test_processDeposit_pushesFundsToAllocator(
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmount(asset, amount);

        vm.expectCall(address(mockAllocator), abi.encodeWithSelector(IAllocator.deposit.selector, asset, amount));

        vm.prank(address(mockStableVault));
        uint256 netDepositAmount = fundsHandler.processDeposit(asset, amount);
        assertEq(netDepositAmount, amount);
    }

    function test_processDeposit_pushesFundsToAllocatorWithSlippage(
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amountOfSlippage,
        uint256 amount
    ) public {
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmountAllowingZero(asset, amount);
        vm.assume(amount > amountOfSlippage);

        vm.expectCall(address(mockAllocator), abi.encodeWithSelector(IAllocator.deposit.selector, asset, amount));
        mockAllocator.mockAmountOfSlippage(amountOfSlippage);
        vm.prank(address(mockStableVault));
        uint256 netDepositAmount = fundsHandler.processDeposit(asset, amount);
        assertEq(netDepositAmount, amount - amountOfSlippage);
    }

    function test_processDeposit_reverts_ifAmountIsZero(bytes32 assetDeploymentSalt, uint8 assetDecimals) public {
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);

        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(address(mockStableVault));
        fundsHandler.processDeposit(asset, 0);
    }

    function test_processDeposit_reverts_ifMsgSenderIsNotTheStableVault(
        address msgSender,
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        _assumeNotProxyAdmin(msgSender, address(fundsHandler));
        vm.assume(msgSender != address(mockStableVault));

        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);

        amount = _boundAssetAmountAllowingZero(address(asset), amount);

        vm.expectRevert(IFundsHandler.OnlyStableVault.selector);
        vm.prank(msgSender);
        fundsHandler.processDeposit(asset, amount);
    }

    function test_processWithdrawal_pullFundsFromAllocator(
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmount(address(asset), amount);

        vm.expectCall(address(mockAllocator), abi.encodeWithSelector(IAllocator.withdraw.selector, asset, amount));

        vm.prank(address(mockStableVault));
        fundsHandler.processWithdrawal(asset, amount);
    }

    function test_processWithdrawal_reverts_ifAmountIsZero(bytes32 assetDeploymentSalt, uint8 assetDecimals) public {
        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);

        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(address(mockStableVault));
        fundsHandler.processWithdrawal(asset, 0);
    }

    function test_processWithdrawal_reverts_ifMsgSenderIsNotTheStableVault(
        address msgSender,
        bytes32 assetDeploymentSalt,
        uint8 assetDecimals,
        uint256 amount
    ) public {
        _assumeNotProxyAdmin(msgSender, address(fundsHandler));
        vm.assume(msgSender != address(mockStableVault));

        address asset = _deployAssetWithSalt(assetDeploymentSalt, assetDecimals);
        amount = _boundAssetAmountAllowingZero(address(asset), amount);

        vm.expectRevert(IFundsHandler.OnlyStableVault.selector);
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

        vm.expectRevert(Errors.OnlyGateway.selector);
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

        vm.expectCall(
            address(mockAllocator), abi.encodeWithSelector(IAllocator.depositAllowIdle.selector, asset, amount)
        );

        vm.prank(address(mockGateway));
        fundsHandler.fundsArrivedFromChainCallback(asset, amount);
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
            unauthorizedMsgSender, address(fundsHandler), IRescuableToken.rescueTokens.selector
        );
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableToken(address(fundsHandler)).rescueTokens(address(mockAsset), assetAmountToRescue);
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

        vm.expectEmit(true, true, true, true);
        emit IRescuableToken.TokensRescued(address(mockAsset), msgSender, assetAmountToRescue);
        vm.prank(msgSender);
        IRescuableToken(address(fundsHandler)).rescueTokens(address(mockAsset), assetAmountToRescue);

        assertEq(mockAsset.balanceOf(msgSender), assetAmountToRescue);
        assertEq(mockAsset.balanceOf(address(fundsHandler)), fhAssetBalance - assetAmountToRescue);
    }

    function test_rescueNative_getExpectedAmountOfNativeAssetToMsgSender(
        uint256 fhAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        // Avoid fuzzing the msgSender address to avoid .call on precompiles and zero address.
        address msgSender = makeAddr("msgSender");

        fhAssetBalance = _boundNativeAmount(fhAssetBalance);
        assetAmountToRescue = _boundNativeAmount(assetAmountToRescue);
        vm.assume(fhAssetBalance >= assetAmountToRescue);

        vm.deal(address(fundsHandler), fhAssetBalance);
        assertEq(address(fundsHandler).balance, fhAssetBalance);
        vm.assume(address(msgSender).balance == 0);

        vm.expectEmit(true, true, true, true);
        emit IRescuableNative.NativeRescued(msgSender, assetAmountToRescue);
        vm.prank(msgSender);
        IRescuableNative(address(fundsHandler)).rescueNative(assetAmountToRescue);

        assertEq(address(msgSender).balance, assetAmountToRescue);
        assertEq(address(fundsHandler).balance, fhAssetBalance - assetAmountToRescue);
    }

    function test_rescueNative_reverts_ifNativeTransferFails(uint256 fhAssetBalance, uint256 assetAmountToRescue)
        public
    {
        fhAssetBalance = _boundNativeAmount(fhAssetBalance);
        assetAmountToRescue = _boundNativeAmount(assetAmountToRescue);
        vm.assume(fhAssetBalance >= assetAmountToRescue);
        vm.deal(address(fundsHandler), fhAssetBalance);
        assertEq(address(fundsHandler).balance, fhAssetBalance);

        // Use a precompile address to force a revert after low level call.
        address msgSender = address(0x09);
        vm.assume(address(msgSender).balance == 0);

        vm.prank(msgSender);
        vm.expectRevert(abi.encodeWithSelector(Errors.NativeTransferFailed.selector));
        IRescuableNative(address(fundsHandler)).rescueNative(assetAmountToRescue);
    }

    function test_pushFundsToChain_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        address asset,
        uint256 amount,
        uint256 chainId,
        uint256 bridgeAdapterData_feeAmount,
        uint256 bridgeAdapterData_gasLimit
    ) public {
        bridgeAdapterData_feeAmount = _boundNativeAmount(bridgeAdapterData_feeAmount);
        vm.deal(address(unauthorizedMsgSender), bridgeAdapterData_feeAmount);
        bytes memory bridgeAdapterData = abi.encode(
            ICcipBridgeAdapter.CcipFeeParams({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeAdapterData_feeAmount, feeRefundThreshold: 0
            })
        );

        vm.assume(chainId != block.chainid);
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);

        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(fundsHandler));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(fundsHandler), IFundsHandler.pushFundsToChain.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        fundsHandler.pushFundsToChain(
            asset, amount, chainId, makeAddr("bridgeAdapter"), bridgeAdapterData_gasLimit, bridgeAdapterData
        );
    }

    /// @dev Under the opaque-bytes dispatch shape the bridge-fee balance-leak check moved from
    /// FundsHandler (via `assertingTransferHelperBalanceForAssets([asset, feeToken])`) to the
    /// adapter layer. The adapter-scope check is covered in `CcipAdapter.t.sol`. FundsHandler
    /// retains only the asset-scope assertion `assertingTransferHelperBalanceFor(asset)`, which is
    /// covered by the `_amountAssetSameAsFeeToken` / `_amountAssetDiffThanFeeToken` tests below.
    /// Fees never transit the TransferHelper in the source flow (the adapter pulls the fee token
    /// directly from the feePayer), so a "fee leak via TransferHelper" scenario at the FundsHandler
    /// layer is no longer reachable and is not tested here.

    function test_pushFundsToChain_reverts_ifAmountIsZero(
        uint256 chainId,
        uint256 bridgeAdapterData_feeAmount,
        uint256 bridgeAdapterData_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);

        bridgeAdapterData_feeAmount = _boundNativeAmount(bridgeAdapterData_feeAmount);
        vm.deal(address(this), bridgeAdapterData_feeAmount);

        bytes memory bridgeAdapterData = abi.encode(
            ICcipBridgeAdapter.CcipFeeParams({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeAdapterData_feeAmount, feeRefundThreshold: 0
            })
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        fundsHandler.pushFundsToChain{value: bridgeAdapterData_feeAmount}(
            address(mockAsset), 0, chainId, makeAddr("bridgeAdapter"), bridgeAdapterData_gasLimit, bridgeAdapterData
        );
    }

    function test_pushFundsToChain_reverts_ifTransferHelperBalanceIsNotFullyConsumed_amountAssetSameAsFeeToken(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeAdapterData_feeAmount,
        uint256 bridgeAdapterData_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeAdapterData_feeAmount = _boundAssetAmount(address(mockAsset), bridgeAdapterData_feeAmount);

        bytes memory bridgeAdapterData = abi.encode(
            ICcipBridgeAdapter.CcipFeeParams({
                feeToken: address(mockAsset), feeAmount: bridgeAdapterData_feeAmount, feeRefundThreshold: 0
            })
        );

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        // Override the adapter so it pulls neither fee nor bridged asset, simulating a downstream
        // that failed to consume the bridged asset; FundsHandler must catch the leftover balance.
        vm.mockCall(
            address(mockBridgeAdapter),
            abi.encodeWithSelector(IBridgeAdapter.publishMessageToChainWithFeePayer.selector),
            ""
        );
        vm.expectRevert(
            abi.encodeWithSelector(TransferHelperClient.TransferHelperBalanceNotConsumed.selector, address(mockAsset))
        );
        fundsHandler.pushFundsToChain(
            address(mockAsset),
            amount,
            chainId,
            address(mockBridgeAdapter),
            bridgeAdapterData_gasLimit,
            bridgeAdapterData
        );
    }

    function test_pushFundsToChain_reverts_ifTransferHelperBalanceIsNotFullyConsumed_amountAssetDiffThanFeeToken(
        uint256 amount,
        uint256 chainId,
        bytes32 feeTokenSalt,
        uint8 feeTokenDecimals,
        uint256 bridgeAdapterData_feeAmount,
        uint256 bridgeAdapterData_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);
        address feeToken = _deployAssetWithSalt(feeTokenSalt, feeTokenDecimals);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeAdapterData_feeAmount = _boundAssetAmount(feeToken, bridgeAdapterData_feeAmount);

        bytes memory bridgeAdapterData = abi.encode(
            ICcipBridgeAdapter.CcipFeeParams({
                feeToken: feeToken, feeAmount: bridgeAdapterData_feeAmount, feeRefundThreshold: 0
            })
        );

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        // Override the adapter so it pulls neither fee nor bridged asset, simulating a downstream
        // that failed to consume the bridged asset; FundsHandler must catch the leftover balance.
        vm.mockCall(
            address(mockBridgeAdapter),
            abi.encodeWithSelector(IBridgeAdapter.publishMessageToChainWithFeePayer.selector),
            ""
        );
        vm.expectRevert(
            abi.encodeWithSelector(TransferHelperClient.TransferHelperBalanceNotConsumed.selector, address(mockAsset))
        );
        fundsHandler.pushFundsToChain(
            address(mockAsset),
            amount,
            chainId,
            address(mockBridgeAdapter),
            bridgeAdapterData_gasLimit,
            bridgeAdapterData
        );
    }

    /// @dev Under the opaque-bytes dispatch shape the `feePayer == msg.sender` guard was dropped
    /// (ERC20 approval semantics already prevent forgery). The former test that asserted
    /// `InvalidBridgeFeePayer` on `feePayer != msg.sender` is replaced by this regression: a
    /// forged `feePayer` who never approved the adapter reverts via the ERC20 layer.
    function test_pushFundsToChain_forgedFeePayer_withoutApproval_revertsWithErc20(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeAdapterData_feeAmount,
        uint256 bridgeAdapterData_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeAdapterData_feeAmount = _boundAssetAmount(address(mockAsset), bridgeAdapterData_feeAmount);
        vm.assume(bridgeAdapterData_feeAmount > 0);
        address unauthorizedFeePayer = makeAddr("unauthorizedFeePayer");
        mockAsset.mint(unauthorizedFeePayer, bridgeAdapterData_feeAmount);

        bytes memory bridgeAdapterData = abi.encode(
            ICcipBridgeAdapter.CcipFeeParams({
                feeToken: address(mockAsset), feeAmount: bridgeAdapterData_feeAmount, feeRefundThreshold: 0
            })
        );

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        // ERC20 allowance semantics reject the forged feePayer — they never approved the adapter.
        vm.expectRevert();
        fundsHandler.pushFundsToChain(
            address(mockAsset),
            amount,
            chainId,
            address(mockBridgeAdapter),
            bridgeAdapterData_gasLimit,
            bridgeAdapterData
        );
    }

    function test_pushFundsToChain_reverts_ifDestinationChainIdNotAddedAsEarningChain(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeAdapterData_feeAmount,
        uint256 bridgeAdapterData_gasLimit
    ) public {
        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeAdapterData_feeAmount = _boundAssetAmount(address(mockAsset), bridgeAdapterData_feeAmount);

        bytes memory bridgeAdapterData = abi.encode(
            ICcipBridgeAdapter.CcipFeeParams({
                feeToken: address(mockAsset), feeAmount: bridgeAdapterData_feeAmount, feeRefundThreshold: 0
            })
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDestinationChainId.selector));
        fundsHandler.pushFundsToChain(
            address(mockAsset),
            amount,
            chainId,
            address(mockBridgeAdapter),
            bridgeAdapterData_gasLimit,
            bridgeAdapterData
        );
    }

    function test_pushFundsToChain_callsGatewaySendPushFundsMessage(
        uint256 amount,
        uint256 chainId,
        uint256 bridgeAdapterData_feeAmount,
        uint256 bridgeAdapterData_gasLimit
    ) public {
        vm.assume(chainId != block.chainid);

        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);

        amount = _boundAssetAmount(address(mockAsset), amount);
        bridgeAdapterData_feeAmount = _boundAssetAmount(address(mockAsset), bridgeAdapterData_feeAmount);
        mockAsset.mint(address(this), bridgeAdapterData_feeAmount);
        // The adapter (not the gateway) is the contract that does safeTransferFrom on the fee
        // token; approval must be set on the adapter to mirror the source flow.
        mockAsset.forceApprove(address(mockBridgeAdapter), bridgeAdapterData_feeAmount);

        bytes memory bridgeAdapterData = abi.encode(
            ICcipBridgeAdapter.CcipFeeParams({
                feeToken: address(mockAsset), feeAmount: bridgeAdapterData_feeAmount, feeRefundThreshold: 0
            })
        );

        mockAsset.mint(address(mockAllocator), amount);
        mockAllocator.mockToPushToTransferHelperInNextCall(address(mockAsset), amount);

        vm.expectCall(
            address(mockGateway),
            abi.encodeCall(
                MockAccountingChainGateway.sendPushFundsToChainMessage,
                (
                    address(mockAsset),
                    amount,
                    chainId,
                    address(mockBridgeAdapter),
                    address(this),
                    bridgeAdapterData_gasLimit,
                    bridgeAdapterData
                )
            )
        );
        fundsHandler.pushFundsToChain(
            address(mockAsset),
            amount,
            chainId,
            address(mockBridgeAdapter),
            bridgeAdapterData_gasLimit,
            bridgeAdapterData
        );
    }

    function test_getEarningChainIds_returnsEmptyByDefault() public view {
        uint256[] memory chainIds = fundsHandler.getEarningChainIds();
        assertEq(chainIds.length, 0);
    }

    function test_getEarningChainIds_returnsAddedChains(uint256 chainId1, uint256 chainId2) public {
        vm.assume(chainId1 != chainId2);
        vm.assume(chainId1 != block.chainid);
        vm.assume(chainId2 != block.chainid);

        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId1);

        uint256[] memory chainIds = fundsHandler.getEarningChainIds();
        assertEq(chainIds.length, 1);
        assertEq(chainIds[0], chainId1);

        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId2);

        chainIds = fundsHandler.getEarningChainIds();
        assertEq(chainIds.length, 2);
        assertEq(chainIds[0], chainId1);
        assertEq(chainIds[1], chainId2);
    }

    function test_getEarningChainIds_reflectsRemoval(uint256 chainId1, uint256 chainId2) public {
        vm.assume(chainId1 != chainId2);
        vm.assume(chainId1 != block.chainid);
        vm.assume(chainId2 != block.chainid);

        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId1);
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId2);

        assertEq(fundsHandler.getEarningChainIds().length, 2);

        vm.prank(ADMIN);
        fundsHandler.removeEarningChain(chainId1);

        uint256[] memory chainIds = fundsHandler.getEarningChainIds();
        assertEq(chainIds.length, 1);
        assertEq(chainIds[0], chainId2);
    }

    function test_addEarningChain_emitsEvent() public {
        uint256 chainId = 1234;
        vm.expectEmit(true, true, true, true);
        emit IFundsHandler.EarningChainAdded(chainId);
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);
    }

    function test_removeEarningChain_emitsEvent() public {
        uint256 chainId = 1234;

        // First add the chain
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);

        // Then remove the chain
        vm.expectEmit(true, true, true, true);
        emit IFundsHandler.EarningChainRemoved(chainId);
        vm.prank(ADMIN);
        fundsHandler.removeEarningChain(chainId);
    }

    function test_addEarningChain_reverts_ifNotCalledByAdmin(address nonAdmin, uint256 chainId) public {
        vm.assume(nonAdmin != ADMIN);
        _assumeNotProxyAdmin(nonAdmin, address(fundsHandler));
        mockAccessManager.mockRejectCall(nonAdmin, address(fundsHandler), IFundsHandler.addEarningChain.selector);
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, nonAdmin));
        fundsHandler.addEarningChain(chainId);
    }

    function test_removeEarningChain_excludesFromBalances(
        uint256 chainId1,
        uint256 chainId2,
        uint256 chainBalance1,
        uint256 chainBalance2
    ) public {
        vm.assume(chainId1 != chainId2);
        vm.assume(chainId1 != block.chainid);
        vm.assume(chainId2 != block.chainid);
        chainBalance1 = _boundAssetAmount(address(mockAsset), chainBalance1);
        chainBalance2 = _boundAssetAmount(address(mockAsset), chainBalance2);

        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId1);

        mockChainBalanceOracle.mockChainBalance(
            chainId1,
            chainBalance1.assetDecimalsToRay(address(mockAsset)),
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId2);
        mockChainBalanceOracle.mockChainBalance(
            chainId2,
            chainBalance2.assetDecimalsToRay(address(mockAsset)),
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        uint256 expectedAggregatedBalance =
            chainBalance1.assetDecimalsToRay(address(mockAsset)) + chainBalance2.assetDecimalsToRay(address(mockAsset));
        assertEq(fundsHandler.getAggregatedBalance(), expectedAggregatedBalance);

        vm.prank(ADMIN);
        fundsHandler.removeEarningChain(chainId1);
        // Only the chainId2 balance is left
        assertEq(fundsHandler.getAggregatedBalance(), chainBalance2.assetDecimalsToRay(address(mockAsset)));
    }

    function test_removeEarningChain_reverts_ifNotCalledByAdmin(address nonAdmin, uint256 chainId) public {
        vm.assume(nonAdmin != ADMIN);
        _assumeNotProxyAdmin(nonAdmin, address(fundsHandler));
        mockAccessManager.mockRejectCall(nonAdmin, address(fundsHandler), IFundsHandler.removeEarningChain.selector);
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, nonAdmin));
        fundsHandler.removeEarningChain(chainId);
    }

    function test_addEarningChain_reverts_ifChainIdAlreadyPresent(uint256 chainId) public {
        vm.assume(chainId != block.chainid);
        vm.prank(ADMIN);
        fundsHandler.addEarningChain(chainId);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IFundsHandler.ChainIdAlreadyPresent.selector));
        fundsHandler.addEarningChain(chainId);
    }

    function test_addEarningChain_reverts_ifChainIdIsTheSameAsTheCurrentChainId() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDestinationChainId.selector));
        fundsHandler.addEarningChain(block.chainid);
    }

    function test_removeEarningChain_reverts_ifChainIdNotPresent(uint256 chainId) public {
        vm.assume(chainId != block.chainid);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IFundsHandler.ChainIdNotPresent.selector));
        fundsHandler.removeEarningChain(chainId);
    }

    //////////////////////////////////////////////// HELPERS ///////////////////////////////////////////////////////////

    function _deployAssetWithSalt(bytes32 assetDeploymentSalt, uint8 assetDecimals) internal returns (address) {
        assetDecimals = _boundAssetDecimals(assetDecimals);
        return address(new MockNonStandardErc20{salt: assetDeploymentSalt}("Test USD", "tUSD", assetDecimals));
    }
}
