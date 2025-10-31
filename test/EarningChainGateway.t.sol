// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EarningChainGateway} from "../src/earning/EarningChainGateway.sol";
import {IAllocator} from "../src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "../src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../src/interfaces/IEarningChainGateway.sol";
import {IIouTokenManager} from "../src/interfaces/IIouTokenManager.sol";
import {AssetLib} from "../src/libraries/AssetLib.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {MathLib} from "../src/libraries/MathLib.sol";
import {TestWithHelpers} from "./helpers/TestWithHelpers.sol";
import {MockAccessManager} from "./mocks/MockAccessManager.sol";
import {MockAllocator} from "./mocks/MockAllocator.sol";
import {MockAssetRegistry} from "./mocks/MockAssetRegistry.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockIouTokenManager} from "./mocks/MockIouTokenManager.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";

contract EarningChainGatewayTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;

    address internal admin = makeAddr("admin");
    address internal everyRoleAccount = makeAddr("everyRoleAccount");

    MockAccessManager internal _mockAccessManager;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    MockAllocator internal _mockAllocator;
    MockBridgeAdapter internal _mockBridgeAdapterAssets;
    MockBridgeAdapter internal _mockBridgeAdapterData;
    MockIouTokenManager internal _mockIouTokenManager;
    MockAssetRegistry internal _mockAssetRegistry;

    EarningChainGateway internal _earningChainGateway;

    function _deployEarningChainGateway(
        MockAccessManager mockAccessManager,
        address iouTokenManager,
        address allocator
    ) internal returns (EarningChainGateway) {
        EarningChainGateway earningChainGateway = new EarningChainGateway(
            address(mockAccessManager), ACCOUNTING_CHAIN_ID, iouTokenManager, allocator
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

        _mockIouTokenManager = new MockIouTokenManager();

        _mockAssetRegistry = new MockAssetRegistry();

        _mockAllocator = new MockAllocator();

        _mockBridgeAdapterAssets = new MockBridgeAdapter();

        _mockBridgeAdapterData = new MockBridgeAdapter();

        _mockAccessManager = new MockAccessManager(admin);

        _earningChainGateway =
            _deployEarningChainGateway(_mockAccessManager, address(_mockIouTokenManager), address(_mockAllocator));
    }

    function test_constructor_setsTheExpectedValues(
        address expectedAdmin,
        address expectedManager,
        uint256 expectedAccountingChainId,
        address expectedIouTokenManager
    ) public {
        vm.assume(expectedAdmin != address(0));
        vm.assume(expectedIouTokenManager != address(0));
        vm.assume(expectedAccountingChainId != 0);
        vm.assume(expectedManager != address(0));

        EarningChainGateway newEarningChainGateway = new EarningChainGateway(
            address(_mockAccessManager), expectedAccountingChainId, expectedIouTokenManager, address(_mockAllocator)
        );
        assertEq(newEarningChainGateway.authority(), address(_mockAccessManager));
        assertEq(newEarningChainGateway.getAccountingChainId(), expectedAccountingChainId);
        assertEq(newEarningChainGateway.getIouTokenManager(), expectedIouTokenManager);
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

    function test_setDefaultBridgeAdatper_revert_ifNotWhitelisted() public {
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

    function test_sendBalanceUpdate_reverts_ifNotManager() public {
        _mockAccessManager.mockRejectCall(
            address(this), address(_earningChainGateway), IEarningChainGateway.sendBalanceUpdate.selector, 0
        );
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        _earningChainGateway.sendBalanceUpdate();
    }

    function test_sendBalanceUpdate_sendsBalanceUpdate(uint256 amountUsdt, uint256 amountGho) public {
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

        vm.prank(everyRoleAccount);
        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChain,
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
                    )
                )
            )
        );
        _earningChainGateway.sendBalanceUpdate();

        // Check when multiple snap shots are sent, the nonce is incremented
        vm.prank(everyRoleAccount);
        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChain,
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
                    )
                )
            )
        );
        _earningChainGateway.sendBalanceUpdate();
    }

    function test_sendBalanceUpdateWithFeePayer_sendsBalanceUpdateWithFeePayerWithTokenBridgeFee(
        uint256 amountUsdt,
        uint256 amountGho,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) public {
        amountUsdt = _boundAssetAmountAllowingZero(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmountAllowingZero(address(_mockGho), amountGho);

        // ERC20 token fee payments only
        vm.assume(bridgeFeeToken != address(0));

        IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

        uint256 expectedTotalAssetsInRay =
            amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
            abi.encode(allocatorBalances)
        );

        address bridgeFeePayer = makeAddr("bridgeFeePayer");

        vm.prank(everyRoleAccount);
        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    bridgeFeePayer,
                    bridgeFeeToken,
                    bridgeFeeAmount,
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                            data: abi.encode(
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 1})
                            )
                        })
                    )
                )
            )
        );
        _earningChainGateway.sendBalanceUpdateWithFeePayer(bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount);

        // Check when multiple snap shots are sent, the nonce is incremented
        vm.prank(everyRoleAccount);
        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    bridgeFeePayer,
                    bridgeFeeToken,
                    bridgeFeeAmount,
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                            data: abi.encode(
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 2})
                            )
                        })
                    )
                )
            )
        );
        _earningChainGateway.sendBalanceUpdateWithFeePayer(bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount);
    }

    function test_sendBalanceUpdateWithFeePayer_sendsBalanceUpdateWithFeePayerWithNativeBridgeFee(
        uint256 amountUsdt,
        uint256 amountGho,
        uint256 bridgeFeeAmount
    ) public {
        amountUsdt = _boundAssetAmountAllowingZero(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmountAllowingZero(address(_mockGho), amountGho);
        bridgeFeeAmount = _boundNativeAmountAllowingZero(bridgeFeeAmount);

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
            bridgeFeeAmount,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    bridgeFeePayer,
                    bridgeFeeToken,
                    bridgeFeeAmount,
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                            data: abi.encode(
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 1})
                            )
                        })
                    )
                )
            )
        );
        _earningChainGateway.sendBalanceUpdateWithFeePayer{value: bridgeFeeAmount}(
            bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount
        );

        // Check when multiple snap shots are sent, the nonce is incremented
        vm.deal(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        vm.expectCall(
            address(_mockBridgeAdapterData),
            bridgeFeeAmount,
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    bridgeFeePayer,
                    bridgeFeeToken,
                    bridgeFeeAmount,
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                            data: abi.encode(
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 2})
                            )
                        })
                    )
                )
            )
        );
        _earningChainGateway.sendBalanceUpdateWithFeePayer{value: bridgeFeeAmount}(
            bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount
        );
    }

    function test_exchangeIouTokens_exchangesIouTokensWithTokenBridgeFee(
        uint256 iouTokenAmountRay,
        address tokenOutReceiver,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) public {
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);
        vm.assume(tokenOutReceiver != address(0));
        vm.assume(bridgeFeePayer != address(0));
        vm.assume(bridgeFeeToken != address(0));

        address tokenOut = address(_mockUsdt);

        // Expect call to IOU token manager to burn tokens
        vm.expectCall(
            address(_mockIouTokenManager),
            abi.encodeCall(MockIouTokenManager.burnTokens, (tokenOutReceiver, iouTokenAmountRay))
        );

        _mockUsdt.mint(address(_mockAllocator), iouTokenAmountRay.rayToAssetDecimals(tokenOut));

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

        // Check the bridge adapter is called with expected parameters
        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOUTOKEN,
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
        vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));
        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    bridgeFeePayer,
                    bridgeFeeToken,
                    bridgeFeeAmount,
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    data
                )
            )
        );

        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay, tokenOut, tokenOutReceiver, bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount
        );

        // Check that another exchange uses incremented nonce
        bytes memory dataInner = abi.encode(
            IChainGateway.BurnIouTokenMessage({
                iouTokenAmountBurnedRay: iouTokenAmountRay,
                chainBalanceSnapshotNonce: 2,
                balanceSnapshotTotalAssetsInRay: expectedTotalAssetsInRay
            })
        );
        _mockUsdt.mint(address(_mockAllocator), amountOut);
        data = abi.encode(
            IChainGateway.CrossChainMessage({messageType: IChainGateway.MessageType.BURN_IOUTOKEN, data: dataInner})
        );
        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    bridgeFeePayer,
                    bridgeFeeToken,
                    bridgeFeeAmount,
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    data
                )
            )
        );
        vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay, tokenOut, tokenOutReceiver, bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount
        );
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
        vm.assume(bridgeFeePayer != address(0));

        address tokenOut = address(_mockUsdt);

        // Setup mocks and expectations
        {
            vm.expectCall(
                address(_mockIouTokenManager),
                abi.encodeCall(MockIouTokenManager.burnTokens, (tokenOutReceiver, iouTokenAmountRay))
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
                    messageType: IChainGateway.MessageType.BURN_IOUTOKEN,
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
            vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));
            vm.expectCall(
                address(_mockBridgeAdapterData),
                abi.encodeCall(
                    IBridgeAdapter.publishMessageToChainWithFeePayer,
                    (
                        bridgeFeePayer,
                        // bridgeFeeToken
                        address(0),
                        bridgeFeeAmount,
                        ACCOUNTING_CHAIN_ID,
                        new IBridgeAdapter.BridgeAsset[](0),
                        data
                    )
                )
            );
        }

        vm.deal(tokenOutReceiver, bridgeFeeAmount);
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens{value: bridgeFeeAmount}(
            iouTokenAmountRay, tokenOut, tokenOutReceiver, bridgeFeePayer, address(0), bridgeFeeAmount
        );
    }

    function test_exchangeIouTokens_reverts_ifZeroAmountAsIouTokenAmountRay() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        _earningChainGateway.exchangeIouTokens(
            0, address(_mockUsdt), makeAddr("tokenOutReceiver"), makeAddr("bridgeFeePayer"), address(0), 0
        );
    }

    function test_exchangeIouTokens_reverts_ifZeroAmountAsBridgeFeeAmount() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        _earningChainGateway.exchangeIouTokens(
            100_000_000_000_000 * 10 ** 27,
            address(_mockUsdt),
            makeAddr("tokenOutReceiver"),
            makeAddr("bridgeFeePayer"),
            address(0),
            0
        );
    }

    function test_exchangeIouTokens_reverts_ifZeroValueForNativeBridgeFee() public {
        vm.expectRevert(ErrorsLib.InsufficientFunds.selector);
        _earningChainGateway.exchangeIouTokens(
            100_000_000_000_000 * 10 ** 27,
            address(_mockUsdt),
            makeAddr("tokenOutReceiver"),
            makeAddr("bridgeFeePayer"),
            address(0),
            123
        );
    }

    function test_exit_bridgesAssetAndSnapshot(uint256 amountTokenUnits) public {
        uint256 amountToken = _boundAssetAmount(address(_mockUsdt), amountTokenUnits);

        // Mock tokens to the Allocator so they can be withdrawn to EarningChainGateway
        _mockUsdt.mint(address(_mockAllocator), amountToken);

        assertEq(IERC20(address(_mockUsdt)).balanceOf(address(_mockAllocator)), amountToken);
        assertEq(IERC20(address(_mockUsdt)).balanceOf(address(_earningChainGateway)), 0);

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
                messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                data: abi.encode(IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 1}))
            })
        );
        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChain,
                (ACCOUNTING_CHAIN_ID, _buildBridgeAssets(address(_mockUsdt), amountToken), data)
            )
        );

        vm.prank(everyRoleAccount);
        _earningChainGateway.exit(address(_mockUsdt), amountToken);

        // Check the balance of Allocator is 0
        assertEq(IERC20(address(_mockUsdt)).balanceOf(address(_mockAllocator)), 0);
        // Check the balance of Gateway is amountTokenUnit
        assertEq(IERC20(address(_mockUsdt)).balanceOf(address(_earningChainGateway)), amountToken);

        // check that the next call uses incremented nonce
        _mockUsdt.mint(address(_mockAllocator), amountToken);
        data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                data: abi.encode(IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 2}))
            })
        );
        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChain,
                (ACCOUNTING_CHAIN_ID, _buildBridgeAssets(address(_mockUsdt), amountToken), data)
            )
        );
        vm.prank(everyRoleAccount);
        _earningChainGateway.exit(address(_mockUsdt), amountToken);
    }

    function test_exit_reverts_ifZeroAmountAsAmount() public {
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.exit(address(_mockUsdt), 0);
    }

    function test_exit_reverts_notManager() public {
        _mockAccessManager.mockRejectCall(
            address(this), address(_earningChainGateway), IEarningChainGateway.exit.selector, 0
        );
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        _earningChainGateway.exit(address(_mockUsdt), 100_000_000_000_000 * 10 ** 6);
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_withTokenBridgeFee(
        address feeRefundRecipient,
        uint256 feeAmount,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        feeAmount = _boundNativeAmount(feeAmount);
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);

        // Use GHO as the bridge fee token
        address feeToken = address(_mockGho);
        // Mimic the IOU token mgr approval of Gateway to pull funds
        IMockErc20(feeToken).mint(address(_mockIouTokenManager), feeAmount);
        vm.prank(address(_mockIouTokenManager));
        MockNonStandardErc20(feeToken).approve(address(_earningChainGateway), feeAmount);

        vm.expectCall(
            feeToken,
            abi.encodeCall(
                IERC20.transferFrom, (address(_mockIouTokenManager), address(_earningChainGateway), feeAmount)
            )
        );
        vm.expectCall(feeToken, abi.encodeCall(IERC20.approve, (address(_mockBridgeAdapterData), feeAmount)));

        // Expect call to Bridge Adapter to publish message with fee payer
        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    feeRefundRecipient,
                    feeToken,
                    feeAmount,
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BRIDGE_IOUTOKEN,
                            data: abi.encode(
                                IChainGateway.IouTokenBridgeMessage({
                                    recipient: iouTokenRecipient, amount: iouTokenAmountRay
                                })
                            )
                        })
                    )
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            feeRefundRecipient, address(_mockGho), feeAmount, ACCOUNTING_CHAIN_ID, iouTokenRecipient, iouTokenAmountRay
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_withNativeBridgeFee(
        address feeRefundRecipient,
        uint256 bridgeFeeAmount,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);

        vm.deal(address(_mockIouTokenManager), bridgeFeeAmount);

        vm.expectCall(
            address(_mockBridgeAdapterData),
            abi.encodeCall(
                IBridgeAdapter.publishMessageToChainWithFeePayer,
                (
                    feeRefundRecipient,
                    address(0),
                    bridgeFeeAmount,
                    ACCOUNTING_CHAIN_ID,
                    new IBridgeAdapter.BridgeAsset[](0),
                    abi.encode(
                        IChainGateway.CrossChainMessage({
                            messageType: IChainGateway.MessageType.BRIDGE_IOUTOKEN,
                            data: abi.encode(
                                IChainGateway.IouTokenBridgeMessage({
                                    recipient: iouTokenRecipient, amount: iouTokenAmountRay
                                })
                            )
                        })
                    )
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer{value: bridgeFeeAmount}(
            feeRefundRecipient, address(0), bridgeFeeAmount, ACCOUNTING_CHAIN_ID, iouTokenRecipient, iouTokenAmountRay
        );
    }

    function test_revert_ifInvalidMessageSender() public {
        // Context: only callable by IOU Token Manager
        vm.expectRevert(ErrorsLib.InvalidMessageSender.selector);
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            makeAddr("feeRefundRecipient"),
            address(_mockUsdt),
            100_000,
            EARNING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000
        );
    }

    function test_revert_ifInvalidDestinationChainId() public {
        vm.prank(address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.InvalidDestinationChainId.selector);
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            makeAddr("feeRefundRecipient"),
            address(_mockUsdt),
            100_000,
            // Can not be the same chain that the Gateway contract is on
            block.chainid,
            makeAddr("iouTokenRecipient"),
            100_000
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifInsufficientFunds() public {
        vm.expectRevert(ErrorsLib.InsufficientFunds.selector);
        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            makeAddr("feeRefundRecipient"),
            address(0),
            100_000,
            ACCOUNTING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000
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
                messageType: IChainGateway.MessageType.BRIDGE_IOUTOKEN,
                data: abi.encode(
                    IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                )
            })
        );
        vm.prank(address(_mockBridgeAdapterData));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), data);
    }

    function test_receiveMessage_whenBridgeFundsIsReceived(uint256 amountUsdt, uint256 amountGho) public {
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
        vm.expectRevert(IChainGateway.UnsupportedAdapter.selector);
        vm.prank(makeAddr("notAdapter"));
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.BRIDGE_IOUTOKEN,
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
