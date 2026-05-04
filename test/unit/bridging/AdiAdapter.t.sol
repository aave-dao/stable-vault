// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {IAdiBridgeAdapter} from "src/interfaces/IAdiBridgeAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAccountingChainGateway} from "test/mocks/MockAccountingChainGateway.sol";
import {MockAdiCrossChainController} from "test/mocks/MockAdiCrossChainController.sol";
import {MockEarningChainGateway} from "test/mocks/MockEarningChainGateway.sol";
import {IMockErc20, MockErc20} from "test/mocks/MockErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract AdiAdapterTest is TestWithHelpers {
    uint256 internal constant ACCOUNTING_CHAIN_ID = 1;
    uint256 internal constant EARNING_CHAIN_ID = 2;
    uint256 internal constant DEFAULT_GAS_LIMIT = 100_000;

    address internal admin = makeAddr("ADMIN");
    address internal everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");
    address internal feePayer = makeAddr("FEE_PAYER");

    MockAccessManager internal _mockAccessManager;
    MockTransferHelper internal _mockTransferHelper;
    MockAdiCrossChainController internal _mockAdiCrossChainController;
    MockAccountingChainGateway internal _accountingChainGateway;
    MockEarningChainGateway internal _earningChainGateway;
    IMockErc20 internal _mockUsdc;
    IMockErc20 internal _mockLink;
    AdiAdapter internal _accountingChainAdiAdapter;
    AdiAdapter internal _earningChainAdiAdapter;

    function setUp() public {
        _mockAccessManager = new MockAccessManager(admin);
        _mockTransferHelper = new MockTransferHelper();
        _mockAdiCrossChainController = new MockAdiCrossChainController();
        _accountingChainGateway = new MockAccountingChainGateway(address(_mockTransferHelper));
        _earningChainGateway = new MockEarningChainGateway(address(_mockTransferHelper));
        _mockUsdc = IMockErc20(address(new MockErc20("Test USDC", "tUSDC", 6)));
        _mockLink = IMockErc20(address(new MockErc20("Test LINK", "tLINK", 18)));

        _accountingChainAdiAdapter = new AdiAdapter(
            address(_mockAccessManager),
            address(_accountingChainGateway),
            address(_mockAdiCrossChainController),
            address(_mockTransferHelper)
        );
        _earningChainAdiAdapter = new AdiAdapter(
            address(_mockAccessManager),
            address(_earningChainGateway),
            address(_mockAdiCrossChainController),
            address(_mockTransferHelper)
        );

        vm.prank(everyRoleAccount);
        _accountingChainAdiAdapter.setDestinationChainAdapter(EARNING_CHAIN_ID, address(_earningChainAdiAdapter));
        vm.prank(everyRoleAccount);
        _earningChainAdiAdapter.setDestinationChainAdapter(ACCOUNTING_CHAIN_ID, address(_accountingChainAdiAdapter));
    }

    function test_constructor_reverts_ifInvalidCrossChainController() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new AdiAdapter(
            address(_mockAccessManager), address(_accountingChainGateway), address(0), address(_mockTransferHelper)
        );
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        new AdiAdapter(
            address(_mockAccessManager),
            address(_accountingChainGateway),
            address(_mockAdiCrossChainController),
            address(0)
        );
    }

    function test_constructor_reverts_ifInvalidGateway() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new AdiAdapter(
            address(_mockAccessManager), address(0), address(_mockAdiCrossChainController), address(_mockTransferHelper)
        );
    }

    function test_getCrossChainController() public view {
        assertEq(_accountingChainAdiAdapter.getCrossChainController(), address(_mockAdiCrossChainController));
        assertEq(_earningChainAdiAdapter.getCrossChainController(), address(_mockAdiCrossChainController));
    }

    function test_getGateway() public view {
        assertEq(_accountingChainAdiAdapter.getGateway(), address(_accountingChainGateway));
        assertEq(_earningChainAdiAdapter.getGateway(), address(_earningChainGateway));
    }

    function test_getDestinationChainAdapter_returnsSetAdapter(uint256 chainId, address adapter) public {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);
        vm.assume(chainId != 0 && chainId != block.chainid);
        vm.assume(adapter != address(0));

        assertEq(_accountingChainAdiAdapter.getDestinationChainAdapter(chainId), address(0));

        vm.prank(everyRoleAccount);
        _accountingChainAdiAdapter.setDestinationChainAdapter(chainId, adapter);

        assertEq(_accountingChainAdiAdapter.getDestinationChainAdapter(chainId), adapter);
    }

    function test_getDestinationChainAdapter_reflectsUpdate(uint256 chainId, address adapter1, address adapter2)
        public
    {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);
        vm.assume(chainId != 0 && chainId != block.chainid);
        vm.assume(adapter1 != address(0) && adapter2 != address(0));
        vm.assume(adapter1 != adapter2);

        vm.prank(everyRoleAccount);
        _accountingChainAdiAdapter.setDestinationChainAdapter(chainId, adapter1);
        assertEq(_accountingChainAdiAdapter.getDestinationChainAdapter(chainId), adapter1);

        vm.prank(everyRoleAccount);
        _accountingChainAdiAdapter.setDestinationChainAdapter(chainId, adapter2);
        assertEq(_accountingChainAdiAdapter.getDestinationChainAdapter(chainId), adapter2);
    }

    function test_getDestinationChainAdapter_returnsZeroForUnsetChain(uint256 chainId) public view {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);
        assertEq(_accountingChainAdiAdapter.getDestinationChainAdapter(chainId), address(0));
    }

    function test_setDestinationChainAdapter_emitsDestinationChainAdapterSet(uint256 chainId, address adapter) public {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);
        vm.assume(chainId != 0 && chainId != block.chainid);

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.DestinationChainAdapterSet(chainId, adapter);
        vm.prank(everyRoleAccount);
        _accountingChainAdiAdapter.setDestinationChainAdapter(chainId, adapter);
    }

    function test_setDestinationChainAdapter_reverts_ifChainIdIsZero() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        _accountingChainAdiAdapter.setDestinationChainAdapter(0, makeAddr("adapter"));
    }

    function test_setDestinationChainAdapter_reverts_ifChainIdIsSelf() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        _accountingChainAdiAdapter.setDestinationChainAdapter(block.chainid, makeAddr("adapter"));
    }

    function test_publishMessageToChainWithFeePayer_forwardsDataOnlyMessage() public {
        bytes memory data = abi.encode("bridge-iou-token");

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessagePublished(bytes32(uint256(1)));

        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            data,
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData()
        );

        assertEq(_mockAdiCrossChainController.lastDestinationChainId(), EARNING_CHAIN_ID);
        assertEq(_mockAdiCrossChainController.lastDestination(), address(_earningChainAdiAdapter));
        assertEq(_mockAdiCrossChainController.lastGasLimit(), DEFAULT_GAS_LIMIT);
        assertEq(_mockAdiCrossChainController.getLastMessage(), data);
    }

    function test_publishMessageToChainWithFeePayer_usesTopLevelGasLimit() public {
        uint256 gasLimit = 543_210;
        bytes memory data = abi.encode("bridge-iou-token");

        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, data, feePayer, gasLimit, _bridgeAdapterData()
        );

        assertEq(address(_mockAdiCrossChainController).balance, 0);
        assertEq(_mockAdiCrossChainController.lastGasLimit(), gasLimit);
        assertEq(_mockAdiCrossChainController.getLastMessage(), data);
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifAssetBridgeRequested() public {
        address asset = makeAddr("asset");

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, asset, 1, "", feePayer, DEFAULT_GAS_LIMIT, _bridgeAdapterData()
        );
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifAmountWithoutAssetRequested() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            1,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData()
        );
    }

    function test_publishMessageToChainWithFeePayer_forwardsNativeFundingToCrossChainController() public {
        uint256 nativeAmount = 1 ether;
        vm.deal(address(_accountingChainGateway), nativeAmount);

        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer{value: nativeAmount}(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData()
        );

        assertEq(address(_mockAdiCrossChainController).balance, nativeAmount);
        assertEq(_mockAdiCrossChainController.lastDestinationChainId(), EARNING_CHAIN_ID);
    }

    function test_publishMessageToChainWithFeePayer_pullsErc20FundingToCrossChainController() public {
        uint256 feeAmount = 100e6;
        _stageFee(feePayer, _mockUsdc, feeAmount);

        vm.expectCall(
            address(_mockUsdc),
            abi.encodeCall(IERC20.transferFrom, (feePayer, address(_mockAdiCrossChainController), feeAmount))
        );
        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData(address(_mockUsdc), feeAmount)
        );

        assertEq(_mockUsdc.balanceOf(address(_mockAdiCrossChainController)), feeAmount);
        assertEq(_mockUsdc.balanceOf(address(_accountingChainAdiAdapter)), 0);
    }

    function test_publishMessageToChainWithFeePayer_pullsMultipleErc20Fees() public {
        uint256 usdcAmount = 100e6;
        uint256 linkAmount = 2 ether;
        _stageFee(feePayer, _mockUsdc, usdcAmount);
        _stageFee(feePayer, _mockLink, linkAmount);

        IAdiBridgeAdapter.Fee[] memory fees = new IAdiBridgeAdapter.Fee[](2);
        fees[0] = IAdiBridgeAdapter.Fee({asset: address(_mockUsdc), amount: usdcAmount});
        fees[1] = IAdiBridgeAdapter.Fee({asset: address(_mockLink), amount: linkAmount});

        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, "", feePayer, DEFAULT_GAS_LIMIT, abi.encode(fees)
        );

        assertEq(_mockUsdc.balanceOf(address(_mockAdiCrossChainController)), usdcAmount);
        assertEq(_mockLink.balanceOf(address(_mockAdiCrossChainController)), linkAmount);
    }

    function test_publishMessageToChainWithFeePayer_forwardsNativeAndPullsErc20Funding() public {
        uint256 nativeAmount = 1 ether;
        uint256 feeAmount = 100e6;
        vm.deal(address(_accountingChainGateway), nativeAmount);
        _stageFee(feePayer, _mockUsdc, feeAmount);

        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer{value: nativeAmount}(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData(address(_mockUsdc), feeAmount)
        );

        assertEq(address(_mockAdiCrossChainController).balance, nativeAmount);
        assertEq(_mockUsdc.balanceOf(address(_mockAdiCrossChainController)), feeAmount);
    }

    function test_publishMessageToChainWithFeePayer_revertsFunding_ifForwardMessageReverts() public {
        uint256 nativeAmount = 1 ether;
        uint256 feeAmount = 100e6;
        vm.deal(address(_accountingChainGateway), nativeAmount);
        _stageFee(feePayer, _mockUsdc, feeAmount);
        _mockAdiCrossChainController.setShouldRevertForwardMessage(true);

        vm.expectRevert(MockAdiCrossChainController.ForwardMessageFailed.selector);
        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer{value: nativeAmount}(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData(address(_mockUsdc), feeAmount)
        );

        assertEq(address(_mockAdiCrossChainController).balance, 0);
        assertEq(_mockUsdc.balanceOf(address(_mockAdiCrossChainController)), 0);
    }

    function test_publishMessageToChainWithFeePayer_acceptsEmptyBridgeAdapterData() public {
        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, "", feePayer, DEFAULT_GAS_LIMIT, ""
        );

        assertEq(_mockAdiCrossChainController.lastDestinationChainId(), EARNING_CHAIN_ID);
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifNativeAssetIsInFeeArray() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData(Constants.NATIVE_CURRENCY, 1)
        );
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifZeroAssetIsInFeeArray() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData(address(0), 1)
        );
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifOnlyGateway(address caller) public {
        vm.assume(caller != address(_accountingChainGateway));
        vm.assume(caller != address(_earningChainGateway));

        vm.expectRevert(Errors.OnlyGateway.selector);
        vm.prank(caller);
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData()
        );

        vm.expectRevert(Errors.OnlyGateway.selector);
        vm.prank(caller);
        _earningChainAdiAdapter.publishMessageToChainWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData()
        );
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifDestinationChainAdapterNotSet(uint256 destinationChainId)
        public
    {
        vm.assume(destinationChainId != EARNING_CHAIN_ID);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_accountingChainGateway));
        _accountingChainAdiAdapter.publishMessageToChainWithFeePayer(
            destinationChainId,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            "",
            feePayer,
            DEFAULT_GAS_LIMIT,
            _bridgeAdapterData()
        );
    }

    function test_receiveCrossChainMessage_routesDataToGateway() public {
        bytes memory data = abi.encode("burn-iou-token");

        vm.expectCall(
            address(_earningChainGateway),
            abi.encodeCall(
                IChainGateway.receiveMessage, (ACCOUNTING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, data)
            )
        );

        _mockAdiCrossChainController.deliver(
            address(_earningChainAdiAdapter), address(_accountingChainAdiAdapter), ACCOUNTING_CHAIN_ID, data
        );

        // `vm.expectCall` above asserts the payload routed to the Gateway.
    }

    function test_receiveCrossChainMessage_reverts_ifNotCrossChainController() public {
        vm.expectRevert(IAdiBridgeAdapter.OnlyCrossChainController.selector);
        _earningChainAdiAdapter.receiveCrossChainMessage(address(_accountingChainAdiAdapter), ACCOUNTING_CHAIN_ID, "");
    }

    function test_receiveCrossChainMessage_reverts_ifOriginSenderIsNotTrusted() public {
        vm.expectRevert(IBridgeAdapter.OnlyDestinationChainAdapter.selector);
        _mockAdiCrossChainController.deliver(
            address(_earningChainAdiAdapter), makeAddr("badOriginSender"), ACCOUNTING_CHAIN_ID, ""
        );
    }

    function test_receiveCrossChainMessage_reverts_ifDestinationChainAdapterNotSetForSourceChain(uint256 sourceChainId)
        public
    {
        vm.assume(sourceChainId != ACCOUNTING_CHAIN_ID);

        vm.expectRevert(Errors.InvalidParameter.selector);
        _mockAdiCrossChainController.deliver(
            address(_earningChainAdiAdapter), makeAddr("originSender"), sourceChainId, ""
        );
    }

    function test_receiveCrossChainMessage_reverts_ifGatewayHandlingFails() public {
        bytes memory data = abi.encode("burn-iou-token");

        vm.mockCallRevert(
            address(_earningChainGateway),
            abi.encodeCall(
                IChainGateway.receiveMessage, (ACCOUNTING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, data)
            ),
            abi.encodeWithSelector(Errors.InvalidParameter.selector)
        );

        vm.expectRevert(Errors.InvalidParameter.selector);
        _mockAdiCrossChainController.deliver(
            address(_earningChainAdiAdapter), address(_accountingChainAdiAdapter), ACCOUNTING_CHAIN_ID, data
        );
    }

    function test_setDestinationChainAdapter_reverts_ifNotAuthorized(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _mockAccessManager.mockRejectCall(
            operator, address(_accountingChainAdiAdapter), IBridgeAdapter.setDestinationChainAdapter.selector
        );

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        vm.prank(operator);
        _accountingChainAdiAdapter.setDestinationChainAdapter(EARNING_CHAIN_ID, address(_earningChainAdiAdapter));
    }

    function _stageFee(address payer, IMockErc20 feeToken, uint256 feeAmount) internal {
        feeToken.mint(payer, feeAmount);
        vm.prank(payer);
        feeToken.approve(address(_accountingChainAdiAdapter), feeAmount);
    }

    function _bridgeAdapterData() internal pure returns (bytes memory) {
        IAdiBridgeAdapter.Fee[] memory fees = new IAdiBridgeAdapter.Fee[](0);
        return abi.encode(fees);
    }

    function _bridgeAdapterData(address feeAsset, uint256 feeAmount) internal pure returns (bytes memory) {
        IAdiBridgeAdapter.Fee[] memory fees = new IAdiBridgeAdapter.Fee[](1);
        fees[0] = IAdiBridgeAdapter.Fee({asset: feeAsset, amount: feeAmount});
        return abi.encode(fees);
    }
}
