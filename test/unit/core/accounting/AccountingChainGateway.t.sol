// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BridgeParamsCodec} from "src/bridging/BridgeParamsCodec.sol";
import {AccountingChainGateway} from "src/core/accounting/AccountingChainGateway.sol";
import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";
import {MockBridgeAdapter} from "test/mocks/MockBridgeAdapter.sol";
import {MockChainBalanceOracle} from "test/mocks/MockChainBalanceOracle.sol";
import {MockDummyIouTokenManager} from "test/mocks/MockDummyIouTokenManager.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockFundsHandler} from "test/mocks/MockFundsHandler.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract AccountingChainGatewayTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMockErc20;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;
    uint256 internal DEFAULT_GAS_LIMIT = 100_000;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    MockAccessManager internal _mockAccessManager;
    MockFundsHandler internal _mockFundsHandler;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    IMockErc20 internal _mockUnsupportedAsset;
    MockBridgeAdapter internal _mockBridgeAdapterAssets;
    MockBridgeAdapter internal _mockBridgeAdapterData;
    MockDummyIouTokenManager internal _mockIouTokenManager;
    MockAssetRegistry internal _mockAssetRegistry;
    MockTransferHelper internal _mockTransferHelper;
    MockChainBalanceOracle internal _mockChainBalanceOracle;

    AccountingChainGateway internal _accountingChainGateway;

    function _deployAccountingChainGateway(
        MockAccessManager mockAccessManager,
        address iouTokenManager,
        address fundsHandler,
        address chainBalanceOracle
    ) internal returns (AccountingChainGateway) {
        address accountingChainGatewayImpl = address(
            new AccountingChainGateway(fundsHandler, iouTokenManager, chainBalanceOracle)
        );
        AccountingChainGateway accountingChainGateway = AccountingChainGateway(
            address(
                new TransparentUpgradeableProxy(
                    accountingChainGatewayImpl,
                    address(this),
                    abi.encodeCall(AccountingChainGateway.initialize, (address(mockAccessManager)))
                )
            )
        );

        vm.prank(admin);
        accountingChainGateway.addBridgeAdapter(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE, EARNING_CHAIN_ID, address(_mockBridgeAdapterData)
        );
        vm.prank(admin);
        accountingChainGateway.addBridgeAdapter(address(_mockUsdt), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        accountingChainGateway.addBridgeAdapter(address(_mockGho), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));

        return accountingChainGateway;
    }

    function setUp() public virtual {
        // Warp to a reasonable timestamp to avoid underflow.
        vm.warp(block.timestamp + 1 days);

        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));

        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        _mockUnsupportedAsset =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Asset", "tUNSUPPORTED", 18)));

        _mockIouTokenManager = new MockDummyIouTokenManager();

        _mockAssetRegistry = new MockAssetRegistry();

        _mockTransferHelper = new MockTransferHelper();

        _mockFundsHandler = new MockFundsHandler(address(_mockTransferHelper));

        _mockBridgeAdapterAssets = new MockBridgeAdapter(address(_mockTransferHelper));

        _mockBridgeAdapterData = new MockBridgeAdapter(address(_mockTransferHelper));

        _mockAccessManager = new MockAccessManager(admin);

        _mockChainBalanceOracle = new MockChainBalanceOracle();

        _accountingChainGateway = _deployAccountingChainGateway(
            _mockAccessManager,
            address(_mockIouTokenManager),
            address(_mockFundsHandler),
            address(_mockChainBalanceOracle)
        );
    }

    function test_getFundsHandler_returnsExpectedFundsHandler() public view {
        assertEq(_accountingChainGateway.getFundsHandler(), address(_mockFundsHandler));
    }

    function test_getIouTokenManager_returnsExpectedIouTokenManager() public view {
        assertEq(_accountingChainGateway.getIouTokenManager(), address(_mockIouTokenManager));
    }

    function test_constructor_reverts_ifFundsHandlerIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new AccountingChainGateway(address(0), address(_mockIouTokenManager), address(_mockChainBalanceOracle));
    }

    function test_constructor_reverts_ifChainBalanceOracleIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new AccountingChainGateway(address(_mockFundsHandler), address(_mockIouTokenManager), address(0));
    }

    function test_constructor_reverts_ifInvalidIouTokenManager() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new AccountingChainGateway(address(_mockFundsHandler), address(0), address(_mockChainBalanceOracle));
    }

    function test_rescueTokens_transfersIdleFundsToMsgSender() public {
        address asset = address(_mockUsdt);
        uint256 amount = 1000000000000000000;
        assertEq(_mockUsdt.balanceOf(address(_accountingChainGateway)), 0);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), 0);
        _mockUsdt.mint(address(_accountingChainGateway), amount);
        assertEq(_mockUsdt.balanceOf(address(_accountingChainGateway)), amount);
        vm.expectEmit(true, true, true, true);
        emit IRescuableToken.TokensRescued(asset, everyRoleAccount, amount);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.rescueTokens(asset, amount);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), amount);
        assertEq(_mockUsdt.balanceOf(address(_accountingChainGateway)), 0);
    }

    function test_rescueTokens_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, uint256 amount)
        public
    {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(_accountingChainGateway));
        _mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(_accountingChainGateway), IRescuableToken.rescueTokens.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        _accountingChainGateway.rescueTokens(address(_mockUsdt), amount);
    }

    function test_rescueNative_transfersExpectedAmountToMsgSender(uint256 gatewayBalance, uint256 amountToRescue)
        public
    {
        address msgSender = makeAddr("msgSender");

        gatewayBalance = _boundNativeAmount(gatewayBalance);
        amountToRescue = _boundNativeAmount(amountToRescue);
        vm.assume(gatewayBalance >= amountToRescue);

        vm.deal(address(_accountingChainGateway), gatewayBalance);
        vm.expectEmit(true, true, true, true);
        emit IRescuableNative.NativeRescued(msgSender, amountToRescue);
        vm.prank(msgSender);
        _accountingChainGateway.rescueNative(amountToRescue);

        assertEq(address(msgSender).balance, amountToRescue);
        assertEq(address(_accountingChainGateway).balance, gatewayBalance - amountToRescue);
    }

    function test_rescueNative_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, uint256 amount)
        public
    {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(_accountingChainGateway));
        _mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(_accountingChainGateway), IRescuableNative.rescueNative.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        _accountingChainGateway.rescueNative(amount);
    }

    function test_removeBridgeAdapter_removesBridgeAdapter() public {
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.BridgeAdapterRemoved(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE, EARNING_CHAIN_ID, address(_mockBridgeAdapterData)
        );
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE, EARNING_CHAIN_ID, address(_mockBridgeAdapterData)
        );
    }

    function test_removeBridgeAdapter_reverts_ifNotWhitelisted() public {
        vm.expectRevert(Errors.AddressNotWhitelisted.selector);
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE, EARNING_CHAIN_ID, makeAddr("bridgeAdapter")
        );
    }

    /// @dev `setUp` pre-wires (ASSET_FOR_DATA_ONLY_BRIDGE, EARNING_CHAIN_ID, _mockBridgeAdapterData),
    /// (_mockUsdt, EARNING_CHAIN_ID, _mockBridgeAdapterAssets), and (_mockGho, EARNING_CHAIN_ID, _mockBridgeAdapterAssets).
    /// Fuzz inputs that hit any of those triples must be excluded.
    function _assumeFreshBridgeAdapterTuple(address asset, uint256 chainId, address bridgeAdapter) internal view {
        vm.assume(asset != address(0) && bridgeAdapter != address(0) && chainId != 0 && chainId != block.chainid);
        vm.assume(
            !(asset == Constants.ASSET_FOR_DATA_ONLY_BRIDGE && chainId == EARNING_CHAIN_ID
                && bridgeAdapter == address(_mockBridgeAdapterData))
        );
        vm.assume(
            !(asset == address(_mockUsdt) && chainId == EARNING_CHAIN_ID
                && bridgeAdapter == address(_mockBridgeAdapterAssets))
        );
        vm.assume(
            !(asset == address(_mockGho) && chainId == EARNING_CHAIN_ID
                && bridgeAdapter == address(_mockBridgeAdapterAssets))
        );
    }

    function test_isBridgeAdapterSupported_returnsTrueAfterAdd(address asset, uint256 chainId, address bridgeAdapter)
        public
    {
        _assumeFreshBridgeAdapterTuple(asset, chainId, bridgeAdapter);

        assertFalse(_accountingChainGateway.isBridgeAdapterSupported(asset, chainId, bridgeAdapter));

        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(asset, chainId, bridgeAdapter);

        assertTrue(_accountingChainGateway.isBridgeAdapterSupported(asset, chainId, bridgeAdapter));
    }

    function test_isBridgeAdapterSupported_returnsFalseAfterRemove(
        address asset,
        uint256 chainId,
        address bridgeAdapter
    ) public {
        _assumeFreshBridgeAdapterTuple(asset, chainId, bridgeAdapter);

        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(asset, chainId, bridgeAdapter);
        assertTrue(_accountingChainGateway.isBridgeAdapterSupported(asset, chainId, bridgeAdapter));

        vm.prank(everyRoleAccount);
        _accountingChainGateway.removeBridgeAdapter(asset, chainId, bridgeAdapter);
        assertFalse(_accountingChainGateway.isBridgeAdapterSupported(asset, chainId, bridgeAdapter));
    }

    function test_isBridgeAdapterSupported_returnsFalseForUnsetAdapter(
        address asset,
        uint256 chainId,
        address bridgeAdapter
    ) public view {
        _assumeFreshBridgeAdapterTuple(asset, chainId, bridgeAdapter);
        assertFalse(_accountingChainGateway.isBridgeAdapterSupported(asset, chainId, bridgeAdapter));
    }

    function test_addBridgeAdapter_setsExpectedBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter)
        public
    {
        _assumeFreshBridgeAdapterTuple(asset, chainId, bridgeAdapter);
        vm.prank(admin);
        _accountingChainGateway.addBridgeAdapter(asset, chainId, bridgeAdapter);
        assertTrue(_accountingChainGateway.isBridgeAdapterSupported(asset, chainId, bridgeAdapter));
    }

    function test_addBridgeAdapter_reverts_ifAlreadyAdded() public {
        address bridgeAdapter = makeAddr("bridgeAdapter");
        address asset = address(_mockUsdt);

        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(asset, EARNING_CHAIN_ID, bridgeAdapter);
        vm.expectRevert(Errors.AddressAlreadyWhitelisted.selector);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(asset, EARNING_CHAIN_ID, bridgeAdapter);
    }

    function test_addBridgeAdapter_reverts_ifAdapterIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(address(_mockUsdt), EARNING_CHAIN_ID, address(0));
    }

    function test_addBridgeAdapter_reverts_ifChainIdIsSelf() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(address(_mockUsdt), block.chainid, makeAddr("bridgeAdapter"));
    }

    function test_addBridgeAdapter_reverts_ifChainIdIsZero() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(address(_mockUsdt), 0, makeAddr("bridgeAdapter"));
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_withTokenBridgeFee(
        address bridgeFeePayer,
        uint256 feeAmount,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        feeAmount = _boundNativeAmount(feeAmount);
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        vm.assume(bridgeFeePayer != address(0));

        address bridgeFeeToken = address(_mockGho);
        // Under the opaque-bytes shape the adapter (here MockBridgeAdapter) does safeTransferFrom
        // from feePayer, so mint to feePayer and approve the adapter directly.
        IMockErc20(bridgeFeeToken).mint(bridgeFeePayer, feeAmount);
        vm.prank(bridgeFeePayer);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeAdapterData), feeAmount);

        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: bridgeFeeToken,
                feeAmount: feeAmount,
                feeRefundThreshold: 0,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );

        // Expect call to Bridge Adapter to publish message with fee payer
        vm.expectCall(
            address(_mockBridgeAdapterData),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    EARNING_CHAIN_ID,
                    Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
                    0,
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                            data: abi.encode(
                                IChainGateway.IouTokenBridgeMessage({
                                    recipient: iouTokenRecipient, amount: iouTokenAmountRay
                                })
                            )
                        })
                    ),
                    bridgeFeePayer,
                    DEFAULT_GAS_LIMIT,
                    bridgeParams
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            address(_mockBridgeAdapterData),
            bridgeFeePayer,
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_withNativeBridgeFee(
        address bridgeFeePayer,
        uint256 bridgeFeeAmount,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        vm.assume(bridgeFeePayer != address(0));
        // Native fee is forwarded via msg.value through the gateway and on to the adapter under
        // the opaque-bytes shape. Fund the IOU token manager which acts as the caller.
        vm.deal(address(_mockIouTokenManager), bridgeFeeAmount);

        vm.expectCall(
            address(_mockBridgeAdapterData),
            bridgeFeeAmount,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    EARNING_CHAIN_ID,
                    Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
                    0,
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                            data: abi.encode(
                                IChainGateway.IouTokenBridgeMessage({
                                    recipient: iouTokenRecipient, amount: iouTokenAmountRay
                                })
                            )
                        })
                    ),
                    bridgeFeePayer,
                    DEFAULT_GAS_LIMIT,
                    BridgeParamsCodec.encode(
                        BridgeParamsCodec.BridgeParams({
                            feeToken: Constants.NATIVE_CURRENCY,
                            feeAmount: bridgeFeeAmount,
                            feeRefundThreshold: 0,
                            data: abi.encode(keccak256(hex"c0ffee"))
                        })
                    )
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer{value: bridgeFeeAmount}(
            EARNING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            address(_mockBridgeAdapterData),
            bridgeFeePayer,
            DEFAULT_GAS_LIMIT,
            BridgeParamsCodec.encode(
                BridgeParamsCodec.BridgeParams({
                    feeToken: Constants.NATIVE_CURRENCY,
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    data: abi.encode(keccak256(hex"c0ffee"))
                })
            )
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifInvalidMessageSender() public {
        vm.expectRevert(IChainGateway.OnlyIouTokenManager.selector);
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000,
            address(_mockBridgeAdapterData),
            address(this),
            DEFAULT_GAS_LIMIT,
            BridgeParamsCodec.encode(
                BridgeParamsCodec.BridgeParams({
                    feeToken: address(_mockUsdt), feeAmount: 100_000, feeRefundThreshold: 0, data: ""
                })
            )
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifAdapterNotFound() public {
        // Remove the bridge adapter for message bridge
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE, EARNING_CHAIN_ID, address(_mockBridgeAdapterData)
        );

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockIouTokenManager));
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000,
            address(_mockBridgeAdapterData),
            address(this),
            DEFAULT_GAS_LIMIT,
            BridgeParamsCodec.encode(
                BridgeParamsCodec.BridgeParams({
                    feeToken: address(_mockUsdt),
                    feeAmount: 100_000,
                    feeRefundThreshold: 0,
                    data: abi.encode(keccak256(hex"c0ffee"))
                })
            )
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifIouTokenAmountIsZero() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(address(_mockIouTokenManager));
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            0,
            makeAddr("bridgeAdapter"),
            address(this),
            DEFAULT_GAS_LIMIT,
            BridgeParamsCodec.encode(
                BridgeParamsCodec.BridgeParams({
                    feeToken: address(_mockUsdt), feeAmount: 100_000, feeRefundThreshold: 0, data: ""
                })
            )
        );
    }

    function test_receiveMessage_whenBridgeFundsIsReceived(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        // mint assets to the bridge adapter used for asset bridging to mimic receipt from underlying bridge
        _mockUsdt.mint(address(_mockBridgeAdapterAssets), amountUsdt);
        vm.prank(address(_mockBridgeAdapterAssets));
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_accountingChainGateway), amountUsdt);

        // Expect received assets to be pushed to TransferHelper
        // The assets would be transferred to the TransferHelper from the bridge adapter
        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.fundsArrivedFromChainCallback, (address(_mockUsdt), amountUsdt))
        );

        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "");
    }

    function test_receiveMessage_whenBridgeFundsIsReceived_emitsEvent() public {
        uint256 amountUsdt = 1000000000000000000;
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.FundsReceived(address(_mockUsdt), amountUsdt, EARNING_CHAIN_ID);
        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "");
    }

    function test_receiveMessage_receiveFunds_succeedsWhenUnknownAdapter(uint256 amountUsdt) public {
        // Context: non whitelisted bridge adapter can trigger receival of funds
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        // Create an unwhitelisted bridge adapter
        address unknownAdapter = makeAddr("unknownAdapter");

        // mint assets to the bridge adapter used for asset bridging to mimic receipt from underlying bridge
        _mockUsdt.mint(address(unknownAdapter), amountUsdt);
        vm.prank(address(unknownAdapter));
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_accountingChainGateway), amountUsdt);

        // Expect received assets to be pushed to TransferHelper
        // The assets would be transferred to the TransferHelper from the bridge adapter
        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.fundsArrivedFromChainCallback, (address(_mockUsdt), amountUsdt))
        );

        vm.prank(address(unknownAdapter));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "");
    }

    function test_receiveMessage_noops_whenNoFundsAndNoData() public {
        vm.mockCallRevert(
            address(_mockFundsHandler),
            abi.encodeWithSelector(IFundsHandler.fundsArrivedFromChainCallback.selector),
            bytes("unexpected")
        );

        vm.prank(makeAddr("notAdapter"));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, address(0), 0, "");
    }

    function test_receiveMessage_whenBridgeIouTokenIsReceived(address iouTokenRecipient, uint256 iouTokenAmountRay)
        public
    {
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        // Locked tokens are released to the recipient
        vm.expectCall(
            address(_mockIouTokenManager),
            abi.encodeCall(IIouTokenManager.releaseTokens, (iouTokenRecipient, iouTokenAmountRay))
        );
        // Call must come from whitelisted data bridge bridge adapter
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                    )
                })
            )
        );
    }

    function test_receiveMessage_reverts_whenBridgeIouTokenIsBundledWithFunds(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.DataNotAllowedWithFunds.selector);
        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.IouTokenBridgeMessage({recipient: makeAddr("iouTokenRecipient"), amount: 100_000})
                    )
                })
            )
        );
    }

    function test_receiveMessage_whenBurnIouTokenIsReceived(uint256 iouTokenAmountBurnedRay) public {
        iouTokenAmountBurnedRay = _boundRayAmount(iouTokenAmountBurnedRay);

        // Mock chain balance oracle to have a source block number >= the message block number.
        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            0,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        vm.expectCall(
            address(_mockIouTokenManager), abi.encodeCall(IIouTokenManager.burnLockedTokens, (iouTokenAmountBurnedRay))
        );
        // Call must come from whitelisted data bridge bridge adapter
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.BurnIouTokenMessage({
                            iouTokenAmountBurnedRay: iouTokenAmountBurnedRay,
                            timestamp: block.timestamp,
                            blockNumber: block.number
                        })
                    )
                })
            )
        );
    }

    function test_receiveMessage_reverts_whenBurnIouTokenIsBundledWithFunds(
        uint256 amountUsdt,
        uint256 iouTokenAmountBurnedRay
    ) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        iouTokenAmountBurnedRay = _boundRayAmount(iouTokenAmountBurnedRay);

        vm.expectRevert(IChainGateway.DataNotAllowedWithFunds.selector);
        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.BurnIouTokenMessage({
                            iouTokenAmountBurnedRay: iouTokenAmountBurnedRay,
                            timestamp: block.timestamp,
                            blockNumber: block.number
                        })
                    )
                })
            )
        );
    }

    function test_receiveMessage_reverts_whenBurnIouTokenAndSnapshotBlockIsOlderThanMessage(uint256 iouTokenAmountBurnedRay)
        public
    {
        iouTokenAmountBurnedRay = _boundRayAmount(iouTokenAmountBurnedRay);

        // Move to the next block so we can publish a snapshot with an older source block number.
        vm.roll(block.number + 1);
        // Mock chain balance oracle with a source block number older than the message block number.
        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            0,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS * 2,
            block.number - 1,
            // The check does NOT rely on the stale flag, only on whether the message block is newer than the source
            // snapshot block.
            false
        );

        vm.expectRevert(IAccountingChainGateway.StaleChainBalance.selector);
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.BurnIouTokenMessage({
                            iouTokenAmountBurnedRay: iouTokenAmountBurnedRay,
                            timestamp: block.timestamp,
                            blockNumber: block.number
                        })
                    )
                })
            )
        );
    }

    function test_receiveMessage_whenReturnFundsIsReceived() public {
        // Mock chain balance oracle to have a source block number >= the message block number.
        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            // Amount is not relevant for this test.
            100_000e27,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            // The check does NOT rely on the stale flag, only on whether the message block is newer than the source
            // snapshot block.
            false
        );

        address asset = address(_mockUsdt);
        uint256 amount = 100_000e27;
        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.RETURN_FUNDS,
                data: abi.encode(
                    IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                )
            })
        );

        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, asset, amount, data);
    }

    function test_receiveMessage_whenReturnFundsIsBundledWithFunds(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            100_000e27,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.fundsArrivedFromChainCallback, (address(_mockUsdt), amountUsdt))
        );

        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.RETURN_FUNDS,
                    data: abi.encode(
                        IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                    )
                })
            )
        );
    }

    function test_receiveMessage_reverts_whenReturnFundsAndSnapshotBlockIsOlderThanMessage() public {
        // Move to the next block so we can publish a snapshot with an older source block number.
        vm.roll(block.number + 1);
        // Mock chain balance oracle with a source block number older than the message block number.
        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            0,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS * 2,
            block.number - 1,
            // The check does NOT rely on the stale flag, only on whether the message block is newer than the source
            // snapshot block.
            false
        );

        address asset = address(_mockUsdt);
        uint256 amount = 100_000e27;
        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.RETURN_FUNDS,
                data: abi.encode(
                    IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                )
            })
        );

        vm.expectRevert(IAccountingChainGateway.StaleChainBalance.selector);
        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, asset, amount, data);
    }

    function test_receiveMessage_reverts_whenReturnFundsBundledWithFundsAndSnapshotBlockIsOlderThanMessage(uint256 amountUsdt)
        public
    {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.roll(block.number + 1);
        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            0,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS * 2,
            block.number - 1,
            false
        );

        vm.expectRevert(IAccountingChainGateway.StaleChainBalance.selector);
        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.RETURN_FUNDS,
                    data: abi.encode(
                        IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                    )
                })
            )
        );
    }

    function test_receiveMessage_givenWhitelistedNonDefaultBridgeAdapter(uint256 iouTokenAmountBurnedRay) public {
        // Context: this should be the case for any valid message type

        iouTokenAmountBurnedRay = _boundRayAmount(iouTokenAmountBurnedRay);

        // Mock chain balance oracle to have a source block number >= the message block number.
        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            0,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        // Add a new whitelisted bridge bridge adapter for message bridge
        address unknownAdapter = makeAddr("unknownAdapter");
        vm.prank(admin);
        _accountingChainGateway.addBridgeAdapter(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, EARNING_CHAIN_ID, unknownAdapter);

        vm.expectCall(
            address(_mockIouTokenManager), abi.encodeCall(IIouTokenManager.burnLockedTokens, (iouTokenAmountBurnedRay))
        );
        vm.prank(address(unknownAdapter));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.BurnIouTokenMessage({
                            iouTokenAmountBurnedRay: iouTokenAmountBurnedRay,
                            timestamp: block.timestamp,
                            blockNumber: block.number
                        })
                    )
                })
            )
        );
    }

    function test_receiveMessage_whenReturnFundsBundledWithFunds_givenWhitelistedAssetBridgeAdapter(uint256 amountUsdt)
        public
    {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            100_000e27,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        address unknownAdapter = makeAddr("unknownAdapter");
        vm.prank(admin);
        _accountingChainGateway.addBridgeAdapter(address(_mockUsdt), EARNING_CHAIN_ID, unknownAdapter);

        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.fundsArrivedFromChainCallback, (address(_mockUsdt), amountUsdt))
        );

        vm.prank(unknownAdapter);
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.RETURN_FUNDS,
                    data: abi.encode(
                        IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                    )
                })
            )
        );
    }

    function test_receiveMessage_reverts_ifInvalidMessageType() public {
        vm.expectRevert(IChainGateway.InvalidDataOnlyMessage.selector);
        // Call must come from whitelisted data bridge bridge adapter
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            abi.encode(IChainGateway.CrossChainMessage({messageType: IChainGateway.MessageType.INVALID, data: ""}))
        );

        vm.expectRevert(IChainGateway.InvalidDataOnlyMessage.selector);
        // Call must come from whitelisted data bridge bridge adapter
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(0),
            0,
            abi.encode(IChainGateway.CrossChainMessage({messageType: IChainGateway.MessageType.RETURN_FUNDS, data: ""}))
        );
    }

    function test_receiveMessage_reverts_whenInvalidMessageTypeIsBundledWithFunds(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.DataNotAllowedWithFunds.selector);
        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(IChainGateway.CrossChainMessage({messageType: IChainGateway.MessageType.INVALID, data: ""}))
        );
    }

    function test_receiveMessage_reverts_ifMessageFromUnsupportedAdapter() public {
        // Remove the bridge adapter for message bridge
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE, EARNING_CHAIN_ID, address(_mockBridgeAdapterData)
        );

        // Build a valid burn IOU token message
        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: 100_000, timestamp: block.timestamp, blockNumber: block.number
                    })
                )
            })
        );

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        // Call must come from unsupported bridge adapter
        vm.prank(address(makeAddr("unsupportedAdapter")));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, data);
    }

    function test_receiveMessage_reverts_whenReturnFundsBundledWithFundsFromDataOnlyAdapter(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.RETURN_FUNDS,
                    data: abi.encode(
                        IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                    )
                })
            )
        );
    }

    function test_receiveMessage_reverts_whenReturnFundsBundledWithFundsFromUnsupportedAssetAdapter(uint256 amountUsdt)
        public
    {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(makeAddr("unsupportedAdapter"));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.RETURN_FUNDS,
                    data: abi.encode(
                        IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                    )
                })
            )
        );
    }

    function test_sendPushFundsToChainMessage_sendsFundsToEarningChainWithTokenBridgeFee(
        uint256 amount,
        address bridgeFeePayer,
        uint256 bridgeFeeAmount
    ) public {
        address assetToBridge = address(_mockUsdt);
        amount = _boundAssetAmount(assetToBridge, amount);
        address bridgeFeeToken = address(_mockUsdt);
        bridgeFeeAmount = _boundAssetAmount(bridgeFeeToken, bridgeFeeAmount);
        vm.assume(bridgeFeePayer != address(0));

        // Fee comes via adapter safeTransferFrom under the opaque-bytes shape.
        IMockErc20(bridgeFeeToken).mint(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeAdapterAssets), bridgeFeeAmount);

        // Mimic the FH pushing assets to TransferHelper
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: bridgeFeeToken,
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (EARNING_CHAIN_ID, assetToBridge, amount, "", bridgeFeePayer, DEFAULT_GAS_LIMIT, bridgeParams)
            )
        );
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(
            assetToBridge,
            amount,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterAssets),
            bridgeFeePayer,
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_sendsFundsToEarningChainWithDifferentTokenBridgeFee(
        uint256 amount,
        address bridgeFeePayer,
        uint256 bridgeFeeAmount
    ) public {
        address assetToBridge = address(_mockUsdt);
        amount = _boundAssetAmount(assetToBridge, amount);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(bridgeFeeToken, bridgeFeeAmount);
        vm.assume(bridgeFeePayer != address(0));

        // Fee comes via adapter safeTransferFrom under the opaque-bytes shape.
        IMockErc20(bridgeFeeToken).mint(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeAdapterAssets), bridgeFeeAmount);

        // Mimic the FH pushing assets to TransferHelper
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: bridgeFeeToken,
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (EARNING_CHAIN_ID, assetToBridge, amount, "", bridgeFeePayer, DEFAULT_GAS_LIMIT, bridgeParams)
            )
        );
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(
            assetToBridge,
            amount,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterAssets),
            bridgeFeePayer,
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_withArbitraryData_emitsEvent() public {
        uint256 amount = 1000000000000000000;
        uint256 bridgeFeeAmount = 2000000000000000000;

        address assetToBridge = address(_mockUsdt);
        amount = _boundAssetAmount(assetToBridge, amount);
        // Use native asset
        address bridgeFeeToken = Constants.NATIVE_CURRENCY;
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);

        // Native fee forwarded via msg.value through the gateway to the adapter.
        vm.deal(address(_mockFundsHandler), bridgeFeeAmount);

        // Mimic the FH pushing assets to TransferHelper
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: bridgeFeeToken,
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IChainGateway.FundsSent(assetToBridge, amount, EARNING_CHAIN_ID);
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage{value: bridgeFeeAmount}(
            assetToBridge,
            amount,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterAssets),
            address(_mockFundsHandler),
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_withoutArbitraryData_emitsEvent() public {
        uint256 amount = 1000000000000000000;
        uint256 bridgeFeeAmount = 2000000000000000000;

        address assetToBridge = address(_mockUsdt);
        amount = _boundAssetAmount(assetToBridge, amount);
        // Use native asset
        address bridgeFeeToken = Constants.NATIVE_CURRENCY;
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);

        // Native fee forwarded via msg.value through the gateway to the adapter.
        vm.deal(address(_mockFundsHandler), bridgeFeeAmount);

        // Mimic the FH pushing assets to TransferHelper
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: bridgeFeeToken, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0, data: ""
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IChainGateway.FundsSent(assetToBridge, amount, EARNING_CHAIN_ID);
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage{value: bridgeFeeAmount}(
            assetToBridge,
            amount,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterAssets),
            address(_mockFundsHandler),
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_reverts_ifOnlyFundsHandler() public {
        vm.expectRevert(IAccountingChainGateway.OnlyFundsHandler.selector);
        _accountingChainGateway.sendPushFundsToChainMessage(
            address(_mockUsdt),
            100_000_000_000_000 * 10 ** 6,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterAssets),
            address(this),
            DEFAULT_GAS_LIMIT,
            BridgeParamsCodec.encode(
                BridgeParamsCodec.BridgeParams({
                    feeToken: Constants.NATIVE_CURRENCY,
                    feeAmount: 0,
                    feeRefundThreshold: 0,
                    data: abi.encode(keccak256(hex"c0ffee"))
                })
            )
        );
    }

    function test_sendPushFundsToChainMessage_reverts_ifTargetChainBalanceIsStale() public {
        address assetToBridge = address(_mockUsdt);
        uint256 amount = 1_000e6;

        // Mimic the FH pushing assets to TransferHelper.
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        // Mock a stale chain balance snapshot for the target chain.
        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            0,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS * 2,
            true
        );

        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: 0, feeRefundThreshold: 0, data: ""
            })
        );

        vm.expectRevert(IAccountingChainGateway.StaleChainBalance.selector);
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(
            assetToBridge,
            amount,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterAssets),
            address(_mockFundsHandler),
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_succeeds_ifTargetChainBalanceIsFresh() public {
        address assetToBridge = address(_mockUsdt);
        uint256 amount = 1_000e6;

        // Mimic the FH pushing assets to TransferHelper.
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        // Mock a fresh chain balance snapshot for the target chain.
        _mockChainBalanceOracle.mockChainBalance(
            EARNING_CHAIN_ID,
            0,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: 0, feeRefundThreshold: 0, data: ""
            })
        );

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    EARNING_CHAIN_ID,
                    assetToBridge,
                    amount,
                    "",
                    address(_mockFundsHandler),
                    DEFAULT_GAS_LIMIT,
                    bridgeParams
                )
            )
        );
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(
            assetToBridge,
            amount,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterAssets),
            address(_mockFundsHandler),
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_reverts_ifUnsupportedAdapter() public {
        // Unset the bridge adapter for asset bridging
        address assetToBridge = address(_mockUsdt);
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(assetToBridge, EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));

        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: Constants.NATIVE_CURRENCY,
                feeAmount: 0,
                feeRefundThreshold: 0,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(
            assetToBridge,
            100_000_000_000_000 * 10 ** 6,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterAssets),
            address(_mockFundsHandler),
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_reverts_ifAdapterNeverWhitelisted() public {
        address bogusAdapter = makeAddr("bogusAdapter");
        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: 0, feeRefundThreshold: 0, data: ""
            })
        );

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(
            address(_mockUsdt),
            100e6,
            EARNING_CHAIN_ID,
            bogusAdapter,
            address(_mockFundsHandler),
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_reverts_ifAssetIsDataOnlyBridgeAndAmountIsNonZero() public {
        bytes memory bridgeParams = BridgeParamsCodec.encode(
            BridgeParamsCodec.BridgeParams({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: 0, feeRefundThreshold: 0, data: ""
            })
        );

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            100e6,
            EARNING_CHAIN_ID,
            address(_mockBridgeAdapterData),
            address(_mockFundsHandler),
            DEFAULT_GAS_LIMIT,
            bridgeParams
        );
    }
}
