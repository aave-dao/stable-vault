// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AccountingChainGateway} from "../src/accounting/AccountingChainGateway.sol";
import {IAccountingChainGateway} from "../src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "../src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../src/interfaces/IChainGateway.sol";
import {IFundsHandler} from "../src/interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "../src/interfaces/IIouTokenManager.sol";
import {AssetLib} from "../src/libraries/AssetLib.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {MathLib} from "../src/libraries/MathLib.sol";
import {TestWithHelpers} from "./helpers/TestWithHelpers.sol";
import {MockAccessManager} from "./mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "./mocks/MockAssetRegistry.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";
import {MockDummyIouTokenManager} from "./mocks/MockDummyIouTokenManager.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockFundsHandler} from "./mocks/MockFundsHandler.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "./mocks/MockTransferHelper.sol";

contract AccountingChainGatewayTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMockErc20;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;

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

    AccountingChainGateway internal _accountingChainGateway;

    function _deployAccountingChainGateway(
        MockAccessManager mockAccessManager,
        address iouTokenManager,
        address fundsHandler
    ) internal returns (AccountingChainGateway) {
        address accountingChainGatewayImpl = address(new AccountingChainGateway(fundsHandler, iouTokenManager));
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
        accountingChainGateway.addBridgeAdapter(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        accountingChainGateway.setDefaultBridgeAdapter(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        accountingChainGateway.addBridgeAdapter(address(_mockUsdt), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        accountingChainGateway.setDefaultBridgeAdapter(
            address(_mockUsdt), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        vm.prank(admin);
        accountingChainGateway.addBridgeAdapter(address(_mockGho), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        accountingChainGateway.setDefaultBridgeAdapter(
            address(_mockGho), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );

        return accountingChainGateway;
    }

    function setUp() public virtual {
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

        _accountingChainGateway = _deployAccountingChainGateway(
            _mockAccessManager, address(_mockIouTokenManager), address(_mockFundsHandler)
        );
    }

    function test_getFundsHandler_returnsExpectedFundsHandler() public view {
        assertEq(_accountingChainGateway.getFundsHandler(), address(_mockFundsHandler));
    }

    function test_getDefaultBridgeAdapter_returnsExpectedDefaultBridgeAdapter() public view {
        assertEq(
            _accountingChainGateway.getDefaultBridgeAdapter(address(_mockUsdt), EARNING_CHAIN_ID),
            address(_mockBridgeAdapterAssets)
        );
        assertEq(
            _accountingChainGateway.getDefaultBridgeAdapter(address(_mockGho), EARNING_CHAIN_ID),
            address(_mockBridgeAdapterAssets)
        );
        assertEq(
            _accountingChainGateway.getDefaultBridgeAdapter(address(0), EARNING_CHAIN_ID),
            address(_mockBridgeAdapterData)
        );
    }

    function test_rescueTokens_transfersIdleFundsToMsgSender() public {
        address asset = address(_mockUsdt);
        uint256 amount = 1000000000000000000;
        assertEq(_mockUsdt.balanceOf(address(_accountingChainGateway)), 0);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), 0);
        _mockUsdt.mint(address(_accountingChainGateway), amount);
        assertEq(_mockUsdt.balanceOf(address(_accountingChainGateway)), amount);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.rescueTokens(asset, amount);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), amount);
        assertEq(_mockUsdt.balanceOf(address(_accountingChainGateway)), 0);
    }

    function test_removeBridgeAdapter_removesDefaultBridgeAdapter() public {
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.DefaultBridgeAdapterSet(address(0), EARNING_CHAIN_ID, address(0));
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.BridgeAdapterRemoved(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));
        assertEq(_accountingChainGateway.getDefaultBridgeAdapter(address(0), EARNING_CHAIN_ID), address(0));
    }

    function test_removeBridgeAdapter_forAssetRemovesDefaultBridgeAdapter() public {
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.DefaultBridgeAdapterSet(address(_mockUsdt), EARNING_CHAIN_ID, address(0));
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.BridgeAdapterRemoved(address(_mockUsdt), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(
            address(_mockUsdt), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        assertEq(_accountingChainGateway.getDefaultBridgeAdapter(address(_mockUsdt), EARNING_CHAIN_ID), address(0));
    }

    function test_removeBridgeAdapter_removesBridgeAdapter() public {
        // Add a new adapter and set it as the default
        address adapter = makeAddr("adapter");
        vm.prank(admin);
        _accountingChainGateway.addBridgeAdapter(address(0), EARNING_CHAIN_ID, adapter);
        vm.prank(admin);
        _accountingChainGateway.setDefaultBridgeAdapter(address(0), EARNING_CHAIN_ID, adapter);
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.BridgeAdapterRemoved(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));
        assertEq(_accountingChainGateway.getDefaultBridgeAdapter(address(0), EARNING_CHAIN_ID), adapter);
    }

    function test_removeBridgeAdapter_reverts_ifNotWhitelisted() public {
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(address(0), EARNING_CHAIN_ID, makeAddr("adapter"));
    }

    function test_setDefaultBridgeAdapter_reverts_ifNotWhitelisted() public {
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        vm.prank(admin);
        _accountingChainGateway.setDefaultBridgeAdapter(address(0), EARNING_CHAIN_ID, makeAddr("adapter"));
    }

    function test_addBridgeAdapter_setsExpectedBridgeAdapter(address asset, uint256 chainId, address adapter) public {
        vm.assume(asset != address(0));
        vm.assume(chainId != 0);
        vm.assume(adapter != address(0));
        vm.prank(admin);
        _accountingChainGateway.addBridgeAdapter(asset, chainId, adapter);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.setDefaultBridgeAdapter(asset, chainId, adapter);
        assertEq(_accountingChainGateway.getDefaultBridgeAdapter(asset, chainId), adapter);
    }

    function test_addBridgeAdapter_reverts_ifAlreadyAdded() public {
        address adapter = makeAddr("adapter");
        address asset = address(_mockUsdt);

        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(asset, EARNING_CHAIN_ID, adapter);
        vm.expectRevert(ErrorsLib.AddressAlreadyWhitelisted.selector);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.addBridgeAdapter(asset, EARNING_CHAIN_ID, adapter);
    }

    function test_setDefaultBridgeAdatper_reverts_ifNotWhitelisted() public {
        address adapter = makeAddr("adapter");
        address asset = address(_mockUsdt);

        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        vm.prank(everyRoleAccount);
        _accountingChainGateway.setDefaultBridgeAdapter(asset, EARNING_CHAIN_ID, adapter);
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
        // Mimic the IOU token mgr approval pushing bridge fee to TransferHelper
        IMockErc20(bridgeFeeToken).mint(address(_mockTransferHelper), feeAmount);

        // Expect call to Bridge Adapter to publish message with fee payer
        vm.expectCall(
            address(_mockBridgeAdapterData),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    EARNING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
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
                    IChainGateway.BridgeParams({
                        feePayer: bridgeFeePayer,
                        feeToken: bridgeFeeToken,
                        feeAmount: feeAmount,
                        gasLimit: 100000,
                        data: abi.encode(keccak256(hex"c0ffee"))
                    })
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            IChainGateway.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: bridgeFeeToken,
                feeAmount: feeAmount,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
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
        // Deal assets to the TransferHelper to mimic the IOU Token Manager pushing funds up
        vm.deal(address(_mockTransferHelper), bridgeFeeAmount);

        vm.expectCall(
            address(_mockBridgeAdapterData),
            // native asset would be transferred to TransferHelper from IOU Token Manager
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    EARNING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
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
                    IChainGateway.BridgeParams({
                        feePayer: bridgeFeePayer,
                        feeToken: address(0),
                        feeAmount: bridgeFeeAmount,
                        gasLimit: 100000,
                        data: abi.encode(keccak256(hex"c0ffee"))
                    })
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            IChainGateway.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: address(0),
                feeAmount: bridgeFeeAmount,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifInvalidMessageSender() public {
        vm.expectRevert(ErrorsLib.InvalidMessageSender.selector);
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000,
            IChainGateway.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(_mockUsdt),
                feeAmount: 100_000,
                gasLimit: 100000,
                data: ""
            })
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifInvalidDestinationChainId() public {
        vm.prank(address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.InvalidDestinationChainId.selector);
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            // Can not be the same chain that the Gateway contract is on
            block.chainid,
            makeAddr("iouTokenRecipient"),
            100_000,
            IChainGateway.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(_mockUsdt),
                feeAmount: 100_000,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifAdapterNotFound() public {
        // Remove the adapter for message bridge
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockIouTokenManager));
        _accountingChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000,
            IChainGateway.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(_mockUsdt),
                feeAmount: 100_000,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_receiveMessage_whenBridgeFundsIsReceived(uint256 amountUsdt, uint256 amountGho) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmount(address(_mockGho), amountGho);

        // mint assets to the adapter used for asset bridging to mimic receipt from underlying bridge
        _mockUsdt.mint(address(_mockBridgeAdapterAssets), amountUsdt);
        vm.prank(address(_mockBridgeAdapterAssets));
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_accountingChainGateway), amountUsdt);

        _mockGho.mint(address(_mockBridgeAdapterAssets), amountGho);
        vm.prank(address(_mockBridgeAdapterAssets));
        MockNonStandardErc20(address(_mockGho)).approve(address(_accountingChainGateway), amountGho);

        // Expect received assets to be pushed to TransferHelper
        // The assets would be transferred to the TransferHelper from the adapter
        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.fundsArrivedFromChainCallback, (address(_mockUsdt), amountUsdt))
        );
        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.fundsArrivedFromChainCallback, (address(_mockGho), amountGho))
        );

        IBridgeAdapter.BridgeAsset[] memory bridgeAssets = new IBridgeAdapter.BridgeAsset[](2);
        bridgeAssets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: amountUsdt});
        bridgeAssets[1] = IBridgeAdapter.BridgeAsset({asset: address(_mockGho), amount: amountGho});
        vm.prank(address(_mockBridgeAdapterAssets));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, bridgeAssets, "");
    }

    function test_receiveMessage_receiveFunds_succeedsWhenUnknownAdapter(uint256 amountUsdt, uint256 amountGho) public {
        // Context: non whitelisted adapter can trigger receival of funds
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmount(address(_mockGho), amountGho);

        // Create an unwhitelisted adapter
        address unknownAdapter = makeAddr("unknownAdapter");

        // mint assets to the adapter used for asset bridging to mimic receipt from underlying bridge
        _mockUsdt.mint(address(unknownAdapter), amountUsdt);
        vm.prank(address(unknownAdapter));
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_accountingChainGateway), amountUsdt);

        _mockGho.mint(address(unknownAdapter), amountGho);
        vm.prank(address(unknownAdapter));
        MockNonStandardErc20(address(_mockGho)).approve(address(_accountingChainGateway), amountGho);

        // Expect received assets to be pushed to TransferHelper
        // The assets would be transferred to the TransferHelper from the adapter
        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.fundsArrivedFromChainCallback, (address(_mockUsdt), amountUsdt))
        );
        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.fundsArrivedFromChainCallback, (address(_mockGho), amountGho))
        );

        IBridgeAdapter.BridgeAsset[] memory bridgeAssets = new IBridgeAdapter.BridgeAsset[](2);
        bridgeAssets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: amountUsdt});
        bridgeAssets[1] = IBridgeAdapter.BridgeAsset({asset: address(_mockGho), amount: amountGho});
        vm.prank(address(unknownAdapter));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, bridgeAssets, "");
    }

    function test_receiveMessage_whenBalanceSnapshotIsReceived(uint256 totalAssetsInRay, uint256 nonce) public {
        totalAssetsInRay = _boundRayAmount(totalAssetsInRay);

        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(IFundsHandler.updateChainBalanceCallback, (EARNING_CHAIN_ID, totalAssetsInRay, nonce))
        );
        // Call must come from whitelisted data bridge adapter
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                    data: abi.encode(IChainGateway.BalanceSnapshot({totalAssetsInRay: totalAssetsInRay, nonce: nonce}))
                })
            )
        );
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
        // Call must come from whitelisted data bridge adapter
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
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

    function test_receiveMessage_whenBurnIouTokenIsReceived(
        uint256 iouTokenAmountBurnedRay,
        uint256 chainBalanceSnapshotNonce,
        uint256 balanceSnapshotTotalAssetsInRay
    ) public {
        iouTokenAmountBurnedRay = _boundRayAmount(iouTokenAmountBurnedRay);
        balanceSnapshotTotalAssetsInRay = _boundRayAmount(balanceSnapshotTotalAssetsInRay);

        vm.expectCall(
            address(_mockIouTokenManager), abi.encodeCall(IIouTokenManager.burnLockedTokens, (iouTokenAmountBurnedRay))
        );
        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(
                IFundsHandler.updateChainBalanceCallback,
                (EARNING_CHAIN_ID, balanceSnapshotTotalAssetsInRay, chainBalanceSnapshotNonce)
            )
        );
        // Call must come from whitelisted data bridge adapter
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.BurnIouTokenMessage({
                            iouTokenAmountBurnedRay: iouTokenAmountBurnedRay,
                            chainBalanceSnapshotNonce: chainBalanceSnapshotNonce,
                            balanceSnapshotTotalAssetsInRay: balanceSnapshotTotalAssetsInRay
                        })
                    )
                })
            )
        );
    }

    function test_receiveMessage_givenWhitelistedNonDefaultBridgeAdapter(
        uint256 iouTokenAmountBurnedRay,
        uint256 chainBalanceSnapshotNonce,
        uint256 balanceSnapshotTotalAssetsInRay
    ) public {
        // Context: this should be the case for any valid message type

        iouTokenAmountBurnedRay = _boundRayAmount(iouTokenAmountBurnedRay);
        balanceSnapshotTotalAssetsInRay = _boundRayAmount(balanceSnapshotTotalAssetsInRay);

        // Add a new whitelisted bridge adapter for message bridge
        address unknownAdapter = makeAddr("unknownAdapter");
        vm.prank(admin);
        _accountingChainGateway.addBridgeAdapter(address(0), EARNING_CHAIN_ID, unknownAdapter);

        vm.expectCall(
            address(_mockIouTokenManager), abi.encodeCall(IIouTokenManager.burnLockedTokens, (iouTokenAmountBurnedRay))
        );
        vm.expectCall(
            address(_mockFundsHandler),
            abi.encodeCall(
                IFundsHandler.updateChainBalanceCallback,
                (EARNING_CHAIN_ID, balanceSnapshotTotalAssetsInRay, chainBalanceSnapshotNonce)
            )
        );
        vm.prank(address(unknownAdapter));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.BurnIouTokenMessage({
                            iouTokenAmountBurnedRay: iouTokenAmountBurnedRay,
                            chainBalanceSnapshotNonce: chainBalanceSnapshotNonce,
                            balanceSnapshotTotalAssetsInRay: balanceSnapshotTotalAssetsInRay
                        })
                    )
                })
            )
        );
    }

    function test_receiveMessage_reverts_ifInvalidMessageType() public {
        vm.expectRevert(IChainGateway.InvalidMessageType.selector);
        // Call must come from whitelisted data bridge adapter
        vm.prank(address(_mockBridgeAdapterData));
        _accountingChainGateway.receiveMessage(
            EARNING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            abi.encode(IChainGateway.CrossChainMessage({messageType: IChainGateway.MessageType.INVALID, data: ""}))
        );
    }

    function test_receiveMessage_reverts_ifMessageFromUnsupportedAdapter() public {
        // Remove the adapter for message bridge
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));

        // Build a valid balance snapshot message
        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                data: abi.encode(IChainGateway.BalanceSnapshot({totalAssetsInRay: 100_000, nonce: 0}))
            })
        );

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        // Call must come from unsupported adapter
        vm.prank(address(makeAddr("unsupportedAdapter")));
        _accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), data);
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

        // Mimic the FH pushing bridge fee to TransferHelper
        IMockErc20(bridgeFeeToken).mint(address(_mockTransferHelper), bridgeFeeAmount);

        // Mimic the FH pushing assets to TransferHelper
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        // native asset would be transferred to TransferHelper from IOU Token Manager
        IChainGateway.BridgeParams memory bridgeParams = IChainGateway.BridgeParams({
            feePayer: bridgeFeePayer,
            feeToken: bridgeFeeToken,
            feeAmount: bridgeFeeAmount,
            gasLimit: 100000,
            data: abi.encode(keccak256(hex"c0ffee"))
        });

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (EARNING_CHAIN_ID, _buildBridgeAssets(assetToBridge, amount), "", bridgeParams)
            )
        );
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(assetToBridge, amount, EARNING_CHAIN_ID, bridgeParams);
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

        // Mimic the FH pushing bridge fee to TransferHelper
        IMockErc20(bridgeFeeToken).mint(address(_mockTransferHelper), bridgeFeeAmount);

        // Mimic the FH pushing assets to TransferHelper
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        IChainGateway.BridgeParams memory bridgeParams = IChainGateway.BridgeParams({
            feePayer: bridgeFeePayer,
            feeToken: bridgeFeeToken,
            feeAmount: bridgeFeeAmount,
            gasLimit: 100000,
            data: abi.encode(keccak256(hex"c0ffee"))
        });

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (EARNING_CHAIN_ID, _buildBridgeAssets(assetToBridge, amount), "", bridgeParams)
            )
        );
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(assetToBridge, amount, EARNING_CHAIN_ID, bridgeParams);
    }

    function test_sendPushFundsToChainMessage_sendsFundsToEarningChainWithNativeBridgeFee(
        uint256 amount,
        uint256 bridgeFeeAmount
    ) public {
        address assetToBridge = address(_mockUsdt);
        amount = _boundAssetAmount(assetToBridge, amount);
        // Use native asset
        address bridgeFeeToken = address(0);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);

        // Mimic the FH pushing bridge fee to TransferHelper
        vm.deal(address(_mockTransferHelper), bridgeFeeAmount);

        // Mimic the FH pushing assets to TransferHelper
        IMockErc20(assetToBridge).mint(address(_mockTransferHelper), amount);

        IChainGateway.BridgeParams memory bridgeParams = IChainGateway.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: bridgeFeeToken,
            feeAmount: bridgeFeeAmount,
            gasLimit: 100000,
            data: abi.encode(keccak256(hex"c0ffee"))
        });

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (EARNING_CHAIN_ID, _buildBridgeAssets(assetToBridge, amount), "", bridgeParams)
            )
        );

        vm.deal(address(_mockFundsHandler), bridgeFeeAmount);
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage{value: bridgeFeeAmount}(
            assetToBridge, amount, EARNING_CHAIN_ID, bridgeParams
        );
    }

    function test_sendPushFundsToChainMessage_reverts_ifNotFundsHandler() public {
        vm.expectRevert(IAccountingChainGateway.NotFundsHandler.selector);
        _accountingChainGateway.sendPushFundsToChainMessage(
            address(_mockUsdt),
            100_000_000_000_000 * 10 ** 6,
            EARNING_CHAIN_ID,
            IChainGateway.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendPushFundsToChainMessage_reverts_ifUnsupportedAdapter() public {
        // Unset the adapter for asset bridging
        address assetToBridge = address(_mockUsdt);
        vm.prank(admin);
        _accountingChainGateway.removeBridgeAdapter(assetToBridge, EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));

        IChainGateway.BridgeParams memory bridgeParams = IChainGateway.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(0),
            feeAmount: 0,
            gasLimit: 100000,
            data: abi.encode(keccak256(hex"c0ffee"))
        });

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockFundsHandler));
        _accountingChainGateway.sendPushFundsToChainMessage(
            assetToBridge, 100_000_000_000_000 * 10 ** 6, EARNING_CHAIN_ID, bridgeParams
        );
    }

    function _buildBridgeAssets(address asset, uint256 amount)
        internal
        pure
        returns (IBridgeAdapter.BridgeAsset[] memory)
    {
        IBridgeAdapter.BridgeAsset[] memory bridgeAssets = new IBridgeAdapter.BridgeAsset[](1);
        bridgeAssets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        return bridgeAssets;
    }
}
