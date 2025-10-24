// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {EarningChainGateway} from "../src/earning/EarningChainGateway.sol";
import {IAllocator} from "../src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "../src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../src/interfaces/IEarningChainGateway.sol";
import {AssetLib} from "../src/libraries/AssetLib.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {MathLib} from "../src/libraries/MathLib.sol";
import {MockAllocator} from "./mocks/MockAllocator.sol";
import {MockAssetRegistry} from "./mocks/MockAssetRegistry.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockIouTokenManager} from "./mocks/MockIouTokenManager.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";

import {console} from "forge-std/console.sol";

contract EarningChainGatewayTest is Test {
    using MathLib for uint256;
    using AssetLib for uint256;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");

    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    MockAllocator internal _mockAllocator;
    MockBridgeAdapter internal _mockBridgeAdapterAssets;
    MockBridgeAdapter internal _mockBridgeAdapterData;
    MockIouTokenManager internal _mockIouTokenManager;
    MockAssetRegistry internal _mockAssetRegistry;

    EarningChainGateway internal _earningChainGateway;

    function _deployEarningChainGateway(address iouTokenManager) internal returns (EarningChainGateway) {
        EarningChainGateway earningChainGateway = new EarningChainGateway(admin, ACCOUNTING_CHAIN_ID, iouTokenManager);
        vm.prank(admin);
        earningChainGateway.setManager(manager);
        vm.prank(admin);
        earningChainGateway.setAllocator(address(_mockAllocator));
        vm.prank(admin);
        earningChainGateway.setBridgeAdapter(address(0), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        earningChainGateway.setBridgeAdapter(address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        earningChainGateway.setBridgeAdapter(address(_mockGho), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets));
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

        _earningChainGateway = _deployEarningChainGateway(address(_mockIouTokenManager));
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

        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(expectedAdmin, expectedAccountingChainId, expectedIouTokenManager);
        assertEq(newEarningChainGateway.getAdmin(), expectedAdmin);
        assertEq(newEarningChainGateway.getManager(), address(0));
        assertEq(newEarningChainGateway.getAccountingChainId(), expectedAccountingChainId);
        assertEq(newEarningChainGateway.getIouTokenManager(), expectedIouTokenManager);

        vm.prank(expectedAdmin);
        newEarningChainGateway.setManager(expectedManager);

        assertEq(newEarningChainGateway.getManager(), expectedManager);
    }

    function test_constructor_reverts_ifZeroAddressAsAdmin() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EarningChainGateway(address(0), EARNING_CHAIN_ID, address(_mockIouTokenManager));
    }

    function test_constructor_reverts_ifZeroAddressAsIouTokenManager() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EarningChainGateway(admin, EARNING_CHAIN_ID, address(0));
    }

    function test_constructor_reverts_ifZeroAddressAsManager() public {
        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(admin, EARNING_CHAIN_ID, address(_mockIouTokenManager));
        vm.prank(admin);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        newEarningChainGateway.setManager(address(0));
    }

    function test_setter_reverts_ifZeroAddressAsManager() public {
        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(admin, EARNING_CHAIN_ID, address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(admin);
        newEarningChainGateway.setManager(address(0));
    }

    function test_setter_reverts_ifZeroAddressAsAllocator() public {
        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(admin, EARNING_CHAIN_ID, address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(admin);
        newEarningChainGateway.setManager(address(0));
    }

    function test_setter_setsExpectedBridgeAdapter(address asset, uint256 chainId, address adapter) public {
        vm.assume(asset != address(0));
        vm.assume(chainId != 0);
        vm.assume(adapter != address(0));
        vm.prank(admin);
        _earningChainGateway.setBridgeAdapter(asset, chainId, adapter);
        assertEq(_earningChainGateway.getBridgeAdapter(asset, chainId), adapter);
    }

    function test_setter_reverts_ifZeroAddressAsAdapter() public {
        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(admin, EARNING_CHAIN_ID, address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(admin);
        newEarningChainGateway.setBridgeAdapter(address(0), EARNING_CHAIN_ID, address(0));
    }

    function test_setter_reverts_ifZeroChainIdAsAdapter() public {
        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(admin, EARNING_CHAIN_ID, address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.ZeroChainId.selector);
        vm.prank(admin);
        newEarningChainGateway.setBridgeAdapter(address(0), 0, address(0));
    }

    function test_sendBalanceUpdate_reverts_ifNotManager() public {
        vm.expectRevert(ErrorsLib.NotManager.selector);
        _earningChainGateway.sendBalanceUpdate();
    }

    function test_sendBalanceUpdate_sendsBalanceUpdate_reverts_ifNotManager() public {
        vm.prank(makeAddr("notManager"));
        vm.expectRevert(ErrorsLib.NotManager.selector);
        _earningChainGateway.sendBalanceUpdate();
    }

    function test_sendBalanceUpdate_sendsBalanceUpdate(uint256 amountUsdt, uint256 amountGho) public {
        vm.assume(amountUsdt < 100_000_000_000_000 * 10 ** 6);
        vm.assume(amountGho < 100_000_000_000_000 * 10 ** 18);

        IAllocator.AllocatorBalance[] memory allocatorBalances = new IAllocator.AllocatorBalance[](2);
        allocatorBalances[0] = IAllocator.AllocatorBalance({asset: address(_mockUsdt), amount: amountUsdt});
        allocatorBalances[1] = IAllocator.AllocatorBalance({asset: address(_mockGho), amount: amountGho});

        uint256 expectedTotalAssetsInRay =
            amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
            abi.encode(allocatorBalances)
        );

        vm.prank(manager);
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
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 0})
                            )
                        })
                    )
                )
            )
        );
        _earningChainGateway.sendBalanceUpdate();

        // Check when multiple snap shots are sent, the nonce is incremented
        vm.prank(manager);
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
    }

    function test_sendBalanceUpdateWithFeePayer_sendsBalanceUpdateWithFeePayerWithToken(
        uint256 amountUsdt,
        uint256 amountGho,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) public {
        vm.assume(amountUsdt < 100_000_000_000_000 * 10 ** 6);
        vm.assume(amountGho < 100_000_000_000_000 * 10 ** 18);

        // ERC20 token fee payments only
        vm.assume(bridgeFeeToken != address(0));

        IAllocator.AllocatorBalance[] memory allocatorBalances = new IAllocator.AllocatorBalance[](2);
        allocatorBalances[0] = IAllocator.AllocatorBalance({asset: address(_mockUsdt), amount: amountUsdt});
        allocatorBalances[1] = IAllocator.AllocatorBalance({asset: address(_mockGho), amount: amountGho});

        uint256 expectedTotalAssetsInRay =
            amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getAssetBalances.selector),
            abi.encode(allocatorBalances)
        );

        address bridgeFeePayer = makeAddr("bridgeFeePayer");

        vm.prank(manager);
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
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 0})
                            )
                        })
                    )
                )
            )
        );
        _earningChainGateway.sendBalanceUpdateWithFeePayer(bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount);

        // Check when multiple snap shots are sent, the nonce is incremented
        vm.prank(manager);
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
    }

    function test_sendBalanceUpdateWithFeePayer_sendsBalanceUpdateWithFeePayerWithNative(
        uint256 amountUsdt,
        uint256 amountGho,
        uint256 bridgeFeeAmount
    ) public {
        vm.assume(amountUsdt < 100_000_000_000_000 * 10 ** 6);
        vm.assume(amountGho < 100_000_000_000_000 * 10 ** 18);
        vm.assume(bridgeFeeAmount < 100_000_000_000_000 * 10 ** 18);

        address bridgeFeeToken = address(0);

        IAllocator.AllocatorBalance[] memory allocatorBalances = new IAllocator.AllocatorBalance[](2);
        allocatorBalances[0] = IAllocator.AllocatorBalance({asset: address(_mockUsdt), amount: amountUsdt});
        allocatorBalances[1] = IAllocator.AllocatorBalance({asset: address(_mockGho), amount: amountGho});

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
                                IChainGateway.BalanceSnapshot({totalAssetsInRay: expectedTotalAssetsInRay, nonce: 0})
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
    }
}
