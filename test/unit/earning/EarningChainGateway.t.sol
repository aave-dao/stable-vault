// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {WithdrawalFeeCalculator} from "../../../src/common/WithdrawalFeeCalculator.sol";
import {EarningChainGateway} from "../../../src/earning/EarningChainGateway.sol";
import {IAllocator} from "../../../src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../../../src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../../../src/interfaces/IEarningChainGateway.sol";
import {IIouTokenManager} from "../../../src/interfaces/IIouTokenManager.sol";
import {AssetLib} from "../../../src/libraries/AssetLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {TestWithHelpers} from "../../helpers/TestWithHelpers.sol";
import {MockAccessManager} from "../../mocks/MockAccessManager.sol";
import {MockAllocator} from "../../mocks/MockAllocator.sol";
import {MockAssetRegistry} from "../../mocks/MockAssetRegistry.sol";
import {MockBridgeAdapter} from "../../mocks/MockBridgeAdapter.sol";
import {MockDummyIouTokenManager} from "../../mocks/MockDummyIouTokenManager.sol";
import {IMockErc20} from "../../mocks/MockErc20.sol";
import {MockNonStandardErc20} from "../../mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "../../mocks/MockTransferHelper.sol";

contract EarningChainGatewayTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    MockAccessManager internal _mockAccessManager;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    IMockErc20 internal _mockUnsupportedAsset;
    MockAllocator internal _mockAllocator;
    MockBridgeAdapter internal _mockBridgeAdapterAssets;
    MockBridgeAdapter internal _mockBridgeAdapterData;
    MockDummyIouTokenManager internal _mockIouTokenManager;
    MockAssetRegistry internal _mockAssetRegistry;
    MockTransferHelper internal _mockTransferHelper;
    WithdrawalFeeCalculator internal _withdrawalFeeCalculator;

    EarningChainGateway internal _earningChainGateway;

    function _deployEarningChainGateway(
        MockAccessManager mockAccessManager,
        address assetRegistry,
        address iouTokenManager,
        address allocator,
        address transferHelper,
        address withdrawalFeeCalculator
    ) internal returns (EarningChainGateway) {
        address earningChainGatewayImpl = address(
            new EarningChainGateway(
                ACCOUNTING_CHAIN_ID, allocator, assetRegistry, iouTokenManager, transferHelper, withdrawalFeeCalculator
            )
        );
        EarningChainGateway earningChainGateway = EarningChainGateway(
            address(
                new TransparentUpgradeableProxy(
                    earningChainGatewayImpl,
                    address(this),
                    abi.encodeCall(EarningChainGateway.initialize, address(mockAccessManager))
                )
            )
        );
        vm.prank(admin);
        earningChainGateway.addBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        earningChainGateway.setDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        earningChainGateway.addBridgeAdapter(address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        earningChainGateway.setDefaultBridgeAdapter(
            address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        vm.prank(admin);
        earningChainGateway.addBridgeAdapter(address(_mockGho), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        earningChainGateway.setDefaultBridgeAdapter(
            address(_mockGho), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        return earningChainGateway;
    }

    function setUp() public {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));

        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        _mockUnsupportedAsset =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Asset", "tUNSUPPORTED", 18)));

        _mockIouTokenManager = new MockDummyIouTokenManager();

        _mockAssetRegistry = new MockAssetRegistry();

        _mockAllocator = new MockAllocator();

        _mockTransferHelper = new MockTransferHelper();

        _mockBridgeAdapterAssets = new MockBridgeAdapter(address(_mockTransferHelper));

        _mockBridgeAdapterData = new MockBridgeAdapter(address(_mockTransferHelper));

        _mockAccessManager = new MockAccessManager(admin);

        _withdrawalFeeCalculator = new WithdrawalFeeCalculator(admin);

        _earningChainGateway = _deployEarningChainGateway(
            _mockAccessManager,
            address(_mockAssetRegistry),
            address(_mockIouTokenManager),
            address(_mockAllocator),
            address(_mockTransferHelper),
            address(_withdrawalFeeCalculator)
        );
    }

    function test_getIouTokenManager_returnsExpectedIouTokenManager() public view {
        assertEq(_earningChainGateway.getIouTokenManager(), address(_mockIouTokenManager));
    }

    function test_getAccountingChainId_returnsExpectedAccountingChainId() public view {
        assertEq(_earningChainGateway.getAccountingChainId(), ACCOUNTING_CHAIN_ID);
    }

    function test_getAggregatedBalance_returnsExpectedAggregatedBalance() public view {
        assertEq(_earningChainGateway.getAggregatedBalance(), 0);
    }

    function test_removeBridgeAdapter_removesDefaultBridgeAdapter() public {
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.DefaultBridgeAdapterSet(address(0), ACCOUNTING_CHAIN_ID, address(0));
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.BridgeAdapterRemoved(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        _earningChainGateway.removeBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));
        assertEq(_earningChainGateway.getDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID), address(0));
    }

    function test_removeBridgeAdapter_forAssetRemovesDefaultBridgeAdapter() public {
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.DefaultBridgeAdapterSet(address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(0));
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.BridgeAdapterRemoved(
            address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        vm.prank(admin);
        _earningChainGateway.removeBridgeAdapter(
            address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        assertEq(_earningChainGateway.getDefaultBridgeAdapter(address(_mockUsdt), ACCOUNTING_CHAIN_ID), address(0));
    }

    function test_removeBridgeAdapter_removesBridgeAdapter() public {
        // Add a new adapter and set it as the default
        address adapter = makeAddr("adapter");
        vm.prank(admin);
        _earningChainGateway.addBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, adapter);
        vm.prank(admin);
        _earningChainGateway.setDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, adapter);
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.BridgeAdapterRemoved(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        _earningChainGateway.removeBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));
        assertEq(_earningChainGateway.getDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID), adapter);
    }

    function test_removeBridgeAdapter_reverts_ifNotWhitelisted() public {
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        vm.prank(admin);
        _earningChainGateway.removeBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, makeAddr("adapter"));
    }

    function test_setDefaultBridgeAdapter_reverts_ifNotWhitelisted() public {
        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        vm.prank(admin);
        _earningChainGateway.setDefaultBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, makeAddr("adapter"));
    }

    function test_rescueTokens_transfersIdleFundsToMsgSender() public {
        address asset = address(_mockUsdt);
        uint256 amount = 1000000000000000000;
        assertEq(_mockUsdt.balanceOf(address(_earningChainGateway)), 0);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), 0);
        _mockUsdt.mint(address(_earningChainGateway), amount);
        assertEq(_mockUsdt.balanceOf(address(_earningChainGateway)), amount);
        vm.prank(everyRoleAccount);
        _earningChainGateway.rescueTokens(asset, amount);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), amount);
        assertEq(_mockUsdt.balanceOf(address(_earningChainGateway)), 0);
    }

    function test_addBridgeAdapter_setsExpectedBridgeAdapter(address asset, uint256 chainId, address adapter) public {
        vm.assume(asset != address(0));
        vm.assume(chainId != 0);
        vm.assume(adapter != address(0));
        vm.prank(admin);
        _earningChainGateway.addBridgeAdapter(asset, chainId, adapter);
        vm.prank(everyRoleAccount);
        _earningChainGateway.setDefaultBridgeAdapter(asset, chainId, adapter);
        assertEq(_earningChainGateway.getDefaultBridgeAdapter(asset, chainId), adapter);
    }

    function test_addBridgeAdapter_reverts_ifAlreadyAdded() public {
        address adapter = makeAddr("adapter");
        address asset = address(_mockUsdt);

        vm.prank(everyRoleAccount);
        _earningChainGateway.addBridgeAdapter(asset, ACCOUNTING_CHAIN_ID, adapter);
        vm.expectRevert(ErrorsLib.AddressAlreadyWhitelisted.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.addBridgeAdapter(asset, ACCOUNTING_CHAIN_ID, adapter);
    }

    function test_setDefaultBridgeAdatper_reverts_ifNotWhitelisted() public {
        address adapter = makeAddr("adapter");
        address asset = address(_mockUsdt);

        vm.expectRevert(ErrorsLib.AddressNotWhitelisted.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.setDefaultBridgeAdapter(asset, ACCOUNTING_CHAIN_ID, adapter);
    }

    function test_getAggregatedBalance_returnsExpectedBalance(uint256 amountUsdt, uint256 amountGho) public {
        amountUsdt = _boundAssetAmountAllowingZero(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmountAllowingZero(address(_mockGho), amountGho);

        IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

        uint256 expectedTotalAssetsInRay =
            amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
            abi.encode(allocatorBalances)
        );
        assertEq(_earningChainGateway.getAggregatedBalance(), expectedTotalAssetsInRay);
    }

    function test_sendBalanceUpdateWithFeePayer_sendsBalanceUpdateWithFeePayerWithTokenBridgeFee(
        uint256 amountUsdt,
        uint256 amountGho,
        uint256 bridgeFeeAmount
    ) public {
        amountUsdt = _boundAssetAmountAllowingZero(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmountAllowingZero(address(_mockGho), amountGho);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(address(_mockGho), bridgeFeeAmount);

        IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

        uint256 expectedTotalAssetsInRay =
            amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
            abi.encode(allocatorBalances)
        );

        address bridgeFeePayer = makeAddr("bridgeFeePayer");

        _mockGho.mint(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);

        vm.expectCall(
            bridgeFeeToken,
            abi.encodeCall(IERC20.transferFrom, (bridgeFeePayer, address(_mockTransferHelper), bridgeFeeAmount))
        );
        vm.expectCall(
            address(_mockBridgeAdapterData),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                            data: abi.encode(
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 1})
                            )
                        })
                    ),
                    IBridgeAdapter.BridgeParams({
                        feePayer: bridgeFeePayer,
                        feeToken: bridgeFeeToken,
                        feeAmount: bridgeFeeAmount,
                        feeRefundThreshold: 0,
                        gasLimit: 100000,
                        data: abi.encode(keccak256(hex"c0ffee"))
                    })
                )
            )
        );
        vm.prank(everyRoleAccount);
        _earningChainGateway.sendBalanceUpdateWithFeePayer(
            IBridgeAdapter.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: bridgeFeeToken,
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );

        // Check when multiple snap shots are sent, the nonce is incremented
        _mockGho.mint(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);

        vm.expectCall(
            bridgeFeeToken,
            abi.encodeCall(IERC20.transferFrom, (bridgeFeePayer, address(_mockTransferHelper), bridgeFeeAmount))
        );
        vm.expectCall(
            address(_mockBridgeAdapterData),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                            data: abi.encode(
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 2})
                            )
                        })
                    ),
                    IBridgeAdapter.BridgeParams({
                        feePayer: bridgeFeePayer,
                        feeToken: bridgeFeeToken,
                        feeAmount: bridgeFeeAmount,
                        feeRefundThreshold: 0,
                        gasLimit: 100000,
                        data: abi.encode(keccak256(hex"c0ffee"))
                    })
                )
            )
        );
        vm.prank(everyRoleAccount);
        _earningChainGateway.sendBalanceUpdateWithFeePayer(
            IBridgeAdapter.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: bridgeFeeToken,
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendBalanceUpdateWithFeePayer_sendsBalanceUpdateWithFeePayerWithNativeBridgeFee(
        uint256 amountUsdt,
        uint256 amountGho,
        uint256 bridgeFeeAmount
    ) public {
        amountUsdt = _boundAssetAmountAllowingZero(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmountAllowingZero(address(_mockGho), amountGho);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);

        address bridgeFeeToken = address(0);

        IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

        uint256 expectedTotalAssetsInRay =
            amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
            abi.encode(allocatorBalances)
        );

        address bridgeFeePayer = makeAddr("bridgeFeePayer");

        vm.deal(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        vm.expectCall(
            address(_mockBridgeAdapterData),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                            data: abi.encode(
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 1})
                            )
                        })
                    ),
                    IBridgeAdapter.BridgeParams({
                        feePayer: bridgeFeePayer,
                        feeToken: bridgeFeeToken,
                        feeAmount: bridgeFeeAmount,
                        feeRefundThreshold: 0,
                        gasLimit: 100000,
                        data: abi.encode(keccak256(hex"c0ffee"))
                    })
                )
            )
        );
        _earningChainGateway.sendBalanceUpdateWithFeePayer{value: bridgeFeeAmount}(
            IBridgeAdapter.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: bridgeFeeToken,
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );

        // Check when multiple snap shots are sent, the nonce is incremented
        vm.deal(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        vm.expectCall(
            address(_mockBridgeAdapterData),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                            data: abi.encode(
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 2})
                            )
                        })
                    ),
                    IBridgeAdapter.BridgeParams({
                        feePayer: bridgeFeePayer,
                        feeToken: bridgeFeeToken,
                        feeAmount: bridgeFeeAmount,
                        feeRefundThreshold: 0,
                        gasLimit: 100000,
                        data: abi.encode(keccak256(hex"c0ffee"))
                    })
                )
            )
        );
        _earningChainGateway.sendBalanceUpdateWithFeePayer{value: bridgeFeeAmount}(
            IBridgeAdapter.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: bridgeFeeToken,
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendBalanceUpdateWithFeePayer_reverts_ifNotWhitelistedBridgeAdapter() public {
        // Unset the adapter for message bridge
        vm.prank(admin);
        _earningChainGateway.removeBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        _earningChainGateway.sendBalanceUpdateWithFeePayer(
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(0),
                feeAmount: 123,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendBalanceUpdateWithFeePayer_reverts_ifZeroValueForNativeBridgeFee() public {
        vm.expectRevert(ErrorsLib.InsufficientFunds.selector);
        _earningChainGateway.sendBalanceUpdateWithFeePayer{value: 0}(
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(0),
                feeAmount: 123,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_exchangeIouTokens_exchangesIouTokensWithTokenBridgeFee(
        uint256 iouTokenAmountRay,
        address tokenOutReceiver,
        address bridgeFeePayer,
        uint256 bridgeFeeAmount
    ) public {
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);
        vm.assume(tokenOutReceiver != address(0));
        _assumeNotProxyAdmin(tokenOutReceiver, address(_earningChainGateway));
        vm.assume(bridgeFeePayer != address(0));
        address bridgeFeeToken = address(_mockGho);

        address tokenOut = address(_mockUsdt);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);

        // First exchange
        {
            // Expect call to IOU token manager to burn tokens
            vm.expectCall(
                address(_mockIouTokenManager),
                abi.encodeCall(MockDummyIouTokenManager.burnTokens, (tokenOutReceiver, iouTokenAmountRay))
            );

            _mockUsdt.mint(address(_mockAllocator), amountOut);

            bytes memory data;
            {
                uint256 amountUsdt = 123000000000000000000;
                uint256 amountGho = 4560000000000000;
                IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

                uint256 expectedTotalAssetsInRay =
                    amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));
                vm.mockCall(
                    address(_mockAllocator),
                    abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
                    abi.encode(allocatorBalances)
                );

                data = abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                        data: abi.encode(
                            IChainGateway.BurnIouTokenMessage({
                                iouTokenAmountBurnedRay: iouTokenAmountRay,
                                chainBalanceSnapshotNonce: 1,
                                balanceSnapshotTotalAssetsInRay: expectedTotalAssetsInRay
                            })
                        )
                    })
                );
            }

            // Check the bridge adapter is called with expected parameters
            _mockGho.mint(bridgeFeePayer, bridgeFeeAmount);
            vm.prank(bridgeFeePayer);
            MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);

            vm.expectCall(
                bridgeFeeToken,
                abi.encodeCall(IERC20.transferFrom, (bridgeFeePayer, address(_mockTransferHelper), bridgeFeeAmount))
            );
            vm.expectCall(
                address(_mockBridgeAdapterData),
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (
                        ACCOUNTING_CHAIN_ID,
                        new IBridgeAdapter.BridgeAsset[](0),
                        data,
                        IBridgeAdapter.BridgeParams({
                            feePayer: bridgeFeePayer,
                            feeToken: bridgeFeeToken,
                            feeAmount: bridgeFeeAmount,
                            feeRefundThreshold: 0,
                            gasLimit: 100000,
                            data: abi.encode(keccak256(hex"c0ffee"))
                        })
                    )
                )
            );
            _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);
            vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));

            vm.prank(tokenOutReceiver);
            _earningChainGateway.exchangeIouTokens(
                iouTokenAmountRay,
                tokenOut,
                tokenOutReceiver,
                IBridgeAdapter.BridgeParams({
                    feePayer: bridgeFeePayer,
                    feeToken: bridgeFeeToken,
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    gasLimit: 100000,
                    data: abi.encode(keccak256(hex"c0ffee"))
                }),
                ""
            );
        }

        // Check that another exchange uses incremented nonce
        {
            _mockUsdt.mint(address(_mockAllocator), amountOut);

            bytes memory data;
            {
                uint256 amountUsdt = 123000000000000000000;
                uint256 amountGho = 4560000000000000;

                uint256 expectedTotalAssetsInRay =
                    amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));

                bytes memory dataInner = abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: iouTokenAmountRay,
                        chainBalanceSnapshotNonce: 2,
                        balanceSnapshotTotalAssetsInRay: expectedTotalAssetsInRay
                    })
                );
                data = abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BURN_IOU_TOKEN, data: dataInner
                    })
                );
            }

            _mockGho.mint(bridgeFeePayer, bridgeFeeAmount);
            vm.prank(bridgeFeePayer);
            MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);

            vm.expectCall(
                bridgeFeeToken,
                abi.encodeCall(IERC20.transferFrom, (bridgeFeePayer, address(_mockTransferHelper), bridgeFeeAmount))
            );
            vm.expectCall(
                address(_mockBridgeAdapterData),
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (
                        ACCOUNTING_CHAIN_ID,
                        new IBridgeAdapter.BridgeAsset[](0),
                        data,
                        IBridgeAdapter.BridgeParams({
                            feePayer: bridgeFeePayer,
                            feeToken: bridgeFeeToken,
                            feeAmount: bridgeFeeAmount,
                            feeRefundThreshold: 0,
                            gasLimit: 100000,
                            data: abi.encode(keccak256(hex"c0ffee"))
                        })
                    )
                )
            );
            _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);
            vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));
            vm.prank(tokenOutReceiver);
            _earningChainGateway.exchangeIouTokens(
                iouTokenAmountRay,
                tokenOut,
                tokenOutReceiver,
                IBridgeAdapter.BridgeParams({
                    feePayer: bridgeFeePayer,
                    feeToken: bridgeFeeToken,
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    gasLimit: 100000,
                    data: abi.encode(keccak256(hex"c0ffee"))
                }),
                ""
            );
        }
    }

    function test_exchangeIouTokens_exchangesIouTokensWithNativeBridgeFee(
        uint256 iouTokenAmountRay,
        address tokenOutReceiver,
        address bridgeFeePayer,
        uint256 bridgeFeeAmount
    ) public {
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);
        vm.assume(tokenOutReceiver != address(0));
        _assumeNotProxyAdmin(tokenOutReceiver, address(_earningChainGateway));
        vm.assume(bridgeFeePayer != address(0));

        address tokenOut = address(_mockUsdt);

        IBridgeAdapter.BridgeParams memory bridgeParams;
        // Setup mocks and expectations
        {
            vm.expectCall(
                address(_mockIouTokenManager),
                abi.encodeCall(MockDummyIouTokenManager.burnTokens, (tokenOutReceiver, iouTokenAmountRay))
            );

            _mockUsdt.mint(address(_mockAllocator), iouTokenAmountRay.rayToAssetDecimals(tokenOut));

            uint256 amountUsdt = 123000000000000000000;
            uint256 amountGho = 4560000000000000;
            IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

            vm.mockCall(
                address(_mockAllocator),
                abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
                abi.encode(allocatorBalances)
            );

            uint256 expectedTotalAssetsInRay =
                amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));

            bytes memory data = abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                    data: abi.encode(
                        IChainGateway.BurnIouTokenMessage({
                            iouTokenAmountBurnedRay: iouTokenAmountRay,
                            chainBalanceSnapshotNonce: 1,
                            balanceSnapshotTotalAssetsInRay: expectedTotalAssetsInRay
                        })
                    )
                })
            );

            uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);
            bridgeParams = IBridgeAdapter.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: address(0),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            });
            _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);
            vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));
            vm.expectCall(
                address(_mockBridgeAdapterData),
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (ACCOUNTING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), data, bridgeParams)
                )
            );
        }

        vm.deal(tokenOutReceiver, bridgeFeeAmount);
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens{value: bridgeFeeAmount}(
            iouTokenAmountRay, tokenOut, tokenOutReceiver, bridgeParams, ""
        );
    }

    function test_exchangeIouTokens_reverts_ifZeroAmountAsIouTokenAmountRay() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        _earningChainGateway.exchangeIouTokens(
            0,
            address(_mockUsdt),
            makeAddr("tokenOutReceiver"),
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(0),
                feeAmount: 0,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            }),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifInsufficientValueForNativeBridgeFee(uint256 iouTokenAmountRay) public {
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(address(_mockUsdt));
        // Put funds idle into TH to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);

        vm.expectRevert(ErrorsLib.InsufficientFunds.selector);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            address(_mockUsdt),
            makeAddr("tokenOutReceiver"),
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(0),
                feeAmount: 123,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            }),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifAssetWithdrawalNotAllowed(uint256 iouTokenAmountRay) public {
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(address(_mockUsdt));
        // Put funds idle into TH to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);

        _mockAssetRegistry.mockToDisallowAssetWithdrawals(address(_mockUsdt));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(_mockUsdt)));
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            address(_mockUsdt),
            makeAddr("tokenOutReceiver"),
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(0),
                feeAmount: 123,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            }),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifNotWhitelistedBridgeAdapter() public {
        // Unset the adapter for message bridge
        vm.prank(admin);
        _earningChainGateway.removeBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));

        address tokenOutReceiver = makeAddr("tokenOutReceiver");
        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens(
            100_000_000_000_000 * 10 ** 27,
            address(_mockUsdt),
            tokenOutReceiver,
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(0),
                feeAmount: 123,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            }),
            ""
        );
    }

    function test_pushFundsToAccountingChain_bridgesAssetAndSnapshotWithTokenBridgeFee(
        uint256 amountTokenUnits,
        uint256 bridgeFeeAmount
    ) public {
        uint256 amountToken = _boundAssetAmount(address(_mockUsdt), amountTokenUnits);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(address(_mockGho), bridgeFeeAmount);

        // Mock tokens into TransferHelper to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

        address feePayer = makeAddr("feePayer");

        {
            bytes memory data;
            {
                uint256 amountUsdt = 123000000000000000000;
                uint256 amountGho = 4560000000000000;
                IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

                vm.mockCall(
                    address(_mockAllocator),
                    abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
                    abi.encode(allocatorBalances)
                );

                uint256 expectedTotalAssetsInRay =
                    amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));

                data = abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                        data: abi.encode(
                            IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 1})
                        )
                    })
                );
            }

            _mockGho.mint(feePayer, bridgeFeeAmount);
            vm.prank(feePayer);
            MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);

            vm.expectCall(
                address(_mockBridgeAdapterAssets),
                0,
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (
                        ACCOUNTING_CHAIN_ID,
                        _buildBridgeAssets(address(_mockUsdt), amountToken),
                        data,
                        IBridgeAdapter.BridgeParams({
                            feePayer: feePayer,
                            feeToken: bridgeFeeToken,
                            feeAmount: bridgeFeeAmount,
                            feeRefundThreshold: 0,
                            gasLimit: 100000,
                            data: abi.encode(keccak256(hex"c0ffee"))
                        })
                    )
                )
            );
            vm.expectCall(
                address(_mockAllocator), abi.encodeCall(IAllocator.withdraw, (address(_mockUsdt), amountToken))
            );

            // Call from random account to ensure the fee payer is used
            vm.prank(makeAddr("randomAccount"));
            _earningChainGateway.pushFundsToAccountingChain(
                address(_mockUsdt),
                amountToken,
                IBridgeAdapter.BridgeParams({
                    feePayer: feePayer,
                    feeToken: bridgeFeeToken,
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    gasLimit: 100000,
                    data: abi.encode(keccak256(hex"c0ffee"))
                })
            );
        }

        // check that the next call uses incremented nonce
        {
            _mockGho.mint(feePayer, bridgeFeeAmount);
            vm.prank(feePayer);
            MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);
            _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

            bytes memory data;
            {
                uint256 amountUsdt = 123000000000000000000;
                uint256 amountGho = 4560000000000000;

                uint256 expectedTotalAssetsInRay =
                    amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));

                data = abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                        data: abi.encode(
                            IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 2})
                        )
                    })
                );
            }

            vm.expectCall(
                address(_mockBridgeAdapterAssets),
                0,
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (
                        ACCOUNTING_CHAIN_ID,
                        _buildBridgeAssets(address(_mockUsdt), amountToken),
                        data,
                        IBridgeAdapter.BridgeParams({
                            feePayer: feePayer,
                            feeToken: bridgeFeeToken,
                            feeAmount: bridgeFeeAmount,
                            feeRefundThreshold: 0,
                            gasLimit: 100000,
                            data: abi.encode(keccak256(hex"c0ffee"))
                        })
                    )
                )
            );
            // Call from a different account to ensure the any account can call this function
            vm.prank(everyRoleAccount);
            _earningChainGateway.pushFundsToAccountingChain(
                address(_mockUsdt),
                amountToken,
                IBridgeAdapter.BridgeParams({
                    feePayer: feePayer,
                    feeToken: bridgeFeeToken,
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    gasLimit: 100000,
                    data: abi.encode(keccak256(hex"c0ffee"))
                })
            );
        }
    }

    function test_pushFundsToAccountingChain_bridgesAssetAndSnapshotWithFeeTokenSameAsAsset(
        uint256 amountTokenUnits,
        uint256 bridgeFeeAmount
    ) public {
        uint256 amountToken = _boundAssetAmount(address(_mockGho), amountTokenUnits);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(address(_mockGho), bridgeFeeAmount);

        // Mock tokens into TransferHelper to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockGho), amountToken);

        address feePayer = makeAddr("feePayer");

        {
            bytes memory data;
            {
                uint256 amountUsdt = 123000000000000000000;
                uint256 amountGho = 4560000000000000;
                IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

                vm.mockCall(
                    address(_mockAllocator),
                    abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
                    abi.encode(allocatorBalances)
                );

                uint256 expectedTotalAssetsInRay =
                    amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));

                data = abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                        data: abi.encode(
                            IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 1})
                        )
                    })
                );
            }

            _mockGho.mint(feePayer, bridgeFeeAmount);
            vm.prank(feePayer);
            MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);

            vm.expectCall(
                address(_mockBridgeAdapterAssets),
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (
                        ACCOUNTING_CHAIN_ID,
                        _buildBridgeAssets(address(_mockGho), amountToken),
                        data,
                        IBridgeAdapter.BridgeParams({
                            feePayer: feePayer,
                            feeToken: bridgeFeeToken,
                            feeAmount: bridgeFeeAmount,
                            feeRefundThreshold: 0,
                            gasLimit: 100000,
                            data: abi.encode(keccak256(hex"c0ffee"))
                        })
                    )
                )
            );
            vm.expectCall(
                address(_mockAllocator), abi.encodeCall(IAllocator.withdraw, (address(_mockGho), amountToken))
            );

            // Call from random account to ensure the fee payer is used
            vm.prank(makeAddr("randomAccount"));
            _earningChainGateway.pushFundsToAccountingChain(
                address(_mockGho),
                amountToken,
                IBridgeAdapter.BridgeParams({
                    feePayer: feePayer,
                    feeToken: bridgeFeeToken,
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    gasLimit: 100000,
                    data: abi.encode(keccak256(hex"c0ffee"))
                })
            );
        }

        // check that the next call uses incremented nonce
        {
            _mockGho.mint(feePayer, bridgeFeeAmount);
            vm.prank(feePayer);
            MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);
            _mockTransferHelper.mockAsset(address(_mockGho), amountToken);

            bytes memory data;
            {
                uint256 amountUsdt = 123000000000000000000;
                uint256 amountGho = 4560000000000000;

                uint256 expectedTotalAssetsInRay =
                    amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));

                data = abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                        data: abi.encode(
                            IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 2})
                        )
                    })
                );
            }

            vm.expectCall(
                address(_mockBridgeAdapterAssets),
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (
                        ACCOUNTING_CHAIN_ID,
                        _buildBridgeAssets(address(_mockGho), amountToken),
                        data,
                        IBridgeAdapter.BridgeParams({
                            feePayer: feePayer,
                            feeToken: bridgeFeeToken,
                            feeAmount: bridgeFeeAmount,
                            feeRefundThreshold: 0,
                            gasLimit: 100000,
                            data: abi.encode(keccak256(hex"c0ffee"))
                        })
                    )
                )
            );
            vm.expectCall(
                address(_mockAllocator), abi.encodeCall(IAllocator.withdraw, (address(_mockGho), amountToken))
            );
            // Call from a different account to ensure the any account can call this function
            vm.prank(everyRoleAccount);
            _earningChainGateway.pushFundsToAccountingChain(
                address(_mockGho),
                amountToken,
                IBridgeAdapter.BridgeParams({
                    feePayer: feePayer,
                    feeToken: bridgeFeeToken,
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    gasLimit: 100000,
                    data: abi.encode(keccak256(hex"c0ffee"))
                })
            );
        }
    }

    function test_pushFundsToAccountingChain_bridgesAssetAndSnapshotWithNativeBridgeFee(
        uint256 amountTokenUnits,
        uint256 bridgeFeeAmount
    ) public {
        uint256 amountToken = _boundAssetAmount(address(_mockUsdt), amountTokenUnits);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);

        // Mock tokens into TransferHelper to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

        address bridgeFeeToken = address(0);
        address feePayer = makeAddr("feePayer");

        {
            bytes memory data;
            {
                uint256 amountUsdt = 123000000000000000000;
                uint256 amountGho = 4560000000000000;
                IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

                vm.mockCall(
                    address(_mockAllocator),
                    abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
                    abi.encode(allocatorBalances)
                );

                uint256 expectedTotalAssetsInRay =
                    amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));

                data = abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                        data: abi.encode(
                            IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 1})
                        )
                    })
                );
            }

            vm.deal(feePayer, bridgeFeeAmount);

            vm.expectCall(
                address(_mockBridgeAdapterAssets),
                0,
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (
                        ACCOUNTING_CHAIN_ID,
                        _buildBridgeAssets(address(_mockUsdt), amountToken),
                        data,
                        IBridgeAdapter.BridgeParams({
                            feePayer: feePayer,
                            feeToken: bridgeFeeToken,
                            feeAmount: bridgeFeeAmount,
                            feeRefundThreshold: 0,
                            gasLimit: 100000,
                            data: abi.encode(keccak256(hex"c0ffee"))
                        })
                    )
                )
            );

            vm.prank(feePayer);
            _earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
                address(_mockUsdt),
                amountToken,
                IBridgeAdapter.BridgeParams({
                    feePayer: feePayer,
                    feeToken: bridgeFeeToken,
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    gasLimit: 100000,
                    data: abi.encode(keccak256(hex"c0ffee"))
                })
            );
        }
    }

    function test_pushFundsToAccountingChain_reverts_ifUnauthorized(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_earningChainGateway));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_earningChainGateway),
                bytes4(IEarningChainGateway.pushFundsToAccountingChain.selector)
            ),
            abi.encode(false)
        );

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        vm.prank(operator);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            100_000_000_000_000 * 10 ** 6,
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: 0,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_pushFundsToAccountingChain_reverts_ifZeroAmountAsAmount() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            0,
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: 0,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_pushFundsToAccountingChain_reverts_ifInsufficientValueForNativeBridgeFee(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        // Put funds idle in Allocator to allow withdrawal to EarningChainGateway
        _mockUsdt.mint(address(_mockAllocator), amount);

        vm.expectRevert(ErrorsLib.InsufficientFunds.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            amount,
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: 123,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_pushFundsToAccountingChain_reverts_ifAdapterNotFound(
        uint256 amount,
        address bridgeFeePayer,
        uint256 bridgeFeeAmount
    ) public {
        vm.assume(bridgeFeePayer != address(0));
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(address(_mockGho), bridgeFeeAmount);

        // Remove the adapter for the asset being bridged
        vm.prank(admin);
        _earningChainGateway.removeBridgeAdapter(
            address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );

        // Mock tokens into TransferHelper to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);

        // transfer funds to fee payer
        _mockGho.mint(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_earningChainGateway), bridgeFeeAmount);

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            amount,
            IBridgeAdapter.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: bridgeFeeToken,
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_pushFundsToAccountingChain_reverts_notManager() public {
        _mockAccessManager.mockRejectCall(
            address(this), address(_earningChainGateway), IEarningChainGateway.pushFundsToAccountingChain.selector, 0
        );
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            100_000_000_000_000 * 10 ** 6,
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: 0,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
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

        // Use GHO as the bridge fee token
        address feeToken = address(_mockGho);
        // Mimic the IOU token mgr approval pushing bridge fee to TransferHelper
        IMockErc20(feeToken).mint(address(_mockTransferHelper), feeAmount);

        // Expect call to Bridge Adapter to publish message with fee payer
        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    ACCOUNTING_CHAIN_ID,
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
                    IBridgeAdapter.BridgeParams({
                        feePayer: bridgeFeePayer,
                        feeToken: feeToken,
                        feeAmount: feeAmount,
                        feeRefundThreshold: 0,
                        gasLimit: 100000,
                        data: abi.encode(keccak256(hex"c0ffee"))
                    })
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            IBridgeAdapter.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: address(_mockGho),
                feeAmount: feeAmount,
                feeRefundThreshold: 0,
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
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    ACCOUNTING_CHAIN_ID,
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
                    IBridgeAdapter.BridgeParams({
                        feePayer: bridgeFeePayer,
                        feeToken: address(0),
                        feeAmount: bridgeFeeAmount,
                        feeRefundThreshold: 0,
                        gasLimit: 100000,
                        data: abi.encode(keccak256(hex"c0ffee"))
                    })
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            IBridgeAdapter.BridgeParams({
                feePayer: bridgeFeePayer,
                feeToken: address(0),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifInvalidMessageSender() public {
        // Context: only callable by IOU Token Manager
        vm.expectRevert(IChainGateway.OnlyIouTokenManager.selector);
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000,
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(_mockUsdt),
                feeAmount: 100_000,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifInvalidDestinationChainId() public {
        vm.prank(address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.InvalidDestinationChainId.selector);
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            // Can not be the same chain that the Gateway contract is on
            block.chainid,
            makeAddr("iouTokenRecipient"),
            100_000,
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(_mockUsdt),
                feeAmount: 100_000,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifAdapterNotFound() public {
        // Remove the adapter for message bridge
        vm.prank(admin);
        _earningChainGateway.removeBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000,
            IBridgeAdapter.BridgeParams({
                feePayer: makeAddr("bridgeFeePayer"),
                feeToken: address(_mockUsdt),
                feeAmount: 100_000,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: abi.encode(keccak256(hex"c0ffee"))
            })
        );
    }

    function test_receiveMessage_whenBridgeIouTokenMessageIsReceived(
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        // Expect call to IouTokenManager to mint tokens
        vm.expectCall(
            address(_mockIouTokenManager),
            abi.encodeCall(IIouTokenManager.mintTokens, (iouTokenRecipient, iouTokenAmountRay))
        );

        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                )
            })
        );
        vm.prank(address(_mockBridgeAdapterData));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), data);
    }

    function test_receiveMessage_givenWhitelistedNonDefaultBridgeAdapter(
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        // Context: this should be the case for any valid message type

        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);

        // Add a new whitelisted bridge adapter for message bridge
        address unknownAdapter = makeAddr("unknownAdapter");
        vm.prank(admin);
        _earningChainGateway.addBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, unknownAdapter);

        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                )
            })
        );
        vm.prank(address(unknownAdapter));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), data);
    }

    function test_receiveMessage_whenBridgeFundsIsReceived(uint256 amountUsdt, uint256 amountGho) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmount(address(_mockGho), amountGho);

        // mint this contract with the assets to mimic the Bridge Adapter
        _mockUsdt.mint(address(_mockBridgeAdapterAssets), amountUsdt);
        vm.prank(address(_mockBridgeAdapterAssets));
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_earningChainGateway), amountUsdt);
        _mockGho.mint(address(_mockBridgeAdapterAssets), amountGho);
        vm.prank(address(_mockBridgeAdapterAssets));
        MockNonStandardErc20(address(_mockGho)).approve(address(_earningChainGateway), amountGho);

        vm.expectCall(address(_mockAllocator), abi.encodeCall(IAllocator.deposit, (address(_mockUsdt), amountUsdt)));
        vm.expectCall(address(_mockAllocator), abi.encodeCall(IAllocator.deposit, (address(_mockGho), amountGho)));

        IBridgeAdapter.BridgeAsset[] memory bridgeAssets = new IBridgeAdapter.BridgeAsset[](2);
        bridgeAssets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: amountUsdt});
        bridgeAssets[1] = IBridgeAdapter.BridgeAsset({asset: address(_mockGho), amount: amountGho});
        vm.prank(address(_mockBridgeAdapterAssets));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, bridgeAssets, "");
    }

    function test_receiveMessage_receiveFunds_succeedsWhenUnknownAdapter(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        address adapter = makeAddr("adapter");
        MockNonStandardErc20(address(_mockUsdt)).mint(address(adapter), amountUsdt);

        IBridgeAdapter.BridgeAsset[] memory bridgeAssets = new IBridgeAdapter.BridgeAsset[](1);
        bridgeAssets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: amountUsdt});

        // Mimic usdt is transferred to the TransferHelper from the adapter
        _mockUsdt.mint(address(_mockTransferHelper), amountUsdt);

        vm.prank(adapter);
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, bridgeAssets, "");

        // Check balance of TransferHelper is amountUsdt as it would not have been pulled down by mock Allocator
        // Funds are transferred to the TransferHelper from the adapter
        assertEq(IERC20(address(_mockUsdt)).balanceOf(address(_mockTransferHelper)), amountUsdt);
    }

    function test_receiveMessage_reverts_ifInvalidMessageType() public {
        vm.prank(address(_mockBridgeAdapterData));
        vm.expectRevert(IChainGateway.InvalidMessageType.selector);
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.INVALID,
                    data: abi.encode(
                        IChainGateway.BalanceSnapshot({totalAssetsInRay: 100_000_000_000_000 * 10 ** 27, nonce: 1})
                    )
                })
            )
        );
    }

    function test_reverts_receiveMessage_ifNotAdapter() public {
        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(makeAddr("notAdapter"));
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
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

    function _buildAllocatorBalances(uint256 amountUsdt, uint256 amountGho)
        internal
        view
        returns (IAllocator.AllocatorBalance[] memory)
    {
        IAllocator.AllocatorBalance[] memory allocatorBalances = new IAllocator.AllocatorBalance[](2);
        allocatorBalances[0] = IAllocator.AllocatorBalance({asset: address(_mockUsdt), amount: amountUsdt});
        allocatorBalances[1] = IAllocator.AllocatorBalance({asset: address(_mockGho), amount: amountGho});
        return allocatorBalances;
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
