// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAccountingChainGateway} from "test/mocks/MockAccountingChainGateway.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";
import {MockCCIPRouter} from "test/mocks/MockCcipRouter.sol";
import {MockEarningChainGateway} from "test/mocks/MockEarningChainGateway.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockGasHeavyReceiver} from "test/mocks/MockGasHeavyReceiver.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockReentrantGateway} from "test/mocks/MockReentrantGateway.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract CcipAdapterTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMockErc20;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint64 internal ACCOUNTING_CHAIN_CCIP_SELECTOR = 10;
    uint256 internal EARNING_CHAIN_ID = 2;
    uint64 internal EARNING_CHAIN_CCIP_SELECTOR = 20;
    uint256 internal DEFAULT_GAS_LIMIT = 100000;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    MockAssetRegistry internal _mockAssetRegistry;
    MockAccessManager internal _mockAccessManager;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    MockTransferHelper internal _mockTransferHelper;
    MockCCIPRouter internal _mockCCIPRouter;
    MockAccountingChainGateway internal _mockAccountingChainGateway;
    MockEarningChainGateway internal _mockEarningChainGateway;

    CcipAdapter internal _accountingChainCcipAdapter;
    CcipAdapter internal _earningChainCcipAdapter;

    function _deployCcipAdapter(address accessManager, address gateway, address ccipRouter, address transferHelper)
        internal
        returns (CcipAdapter)
    {
        CcipAdapter ccipAdapter =
            new CcipAdapter(accessManager, gateway, ccipRouter, transferHelper, address(_mockAssetRegistry));
        return ccipAdapter;
    }

    function setUp() public virtual {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        _mockAssetRegistry = new MockAssetRegistry();
        _mockTransferHelper = new MockTransferHelper();
        _mockAccessManager = new MockAccessManager(admin);

        _mockCCIPRouter = new MockCCIPRouter();

        _mockAccountingChainGateway = new MockAccountingChainGateway(address(_mockTransferHelper));
        _mockEarningChainGateway = new MockEarningChainGateway(address(_mockTransferHelper));

        _accountingChainCcipAdapter = _deployCcipAdapter(
            address(_mockAccessManager),
            address(_mockAccountingChainGateway),
            address(_mockCCIPRouter),
            address(_mockTransferHelper)
        );
        _earningChainCcipAdapter = _deployCcipAdapter(
            address(_mockAccessManager),
            address(_mockEarningChainGateway),
            address(_mockCCIPRouter),
            address(_mockTransferHelper)
        );

        // Set chain selectors and destination adapters
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setChainSelector(EARNING_CHAIN_ID, EARNING_CHAIN_CCIP_SELECTOR);
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setDestinationChainAdapter(EARNING_CHAIN_ID, address(_earningChainCcipAdapter));

        vm.prank(everyRoleAccount);
        _earningChainCcipAdapter.setChainSelector(ACCOUNTING_CHAIN_ID, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        vm.prank(everyRoleAccount);
        _earningChainCcipAdapter.setDestinationChainAdapter(ACCOUNTING_CHAIN_ID, address(_accountingChainCcipAdapter));
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        _deployCcipAdapter(
            address(_mockAccessManager), address(_mockAccountingChainGateway), address(_mockCCIPRouter), address(0)
        );
    }

    function test_getRouter() public view {
        assertEq(_accountingChainCcipAdapter.getRouter(), address(_mockCCIPRouter));
        assertEq(_earningChainCcipAdapter.getRouter(), address(_mockCCIPRouter));
    }

    function test_getGateway() public view {
        assertEq(_accountingChainCcipAdapter.getGateway(), address(_mockAccountingChainGateway));
        assertEq(_earningChainCcipAdapter.getGateway(), address(_mockEarningChainGateway));
    }

    function test_getChainSelector_AccountingChain() public view {
        assertEq(_accountingChainCcipAdapter.getChainSelector(EARNING_CHAIN_ID), EARNING_CHAIN_CCIP_SELECTOR);
        assertEq(_accountingChainCcipAdapter.getChainSelector(ACCOUNTING_CHAIN_ID), 0);
    }

    function test_getChainSelector_EarningChain() public view {
        assertEq(_earningChainCcipAdapter.getChainSelector(ACCOUNTING_CHAIN_ID), ACCOUNTING_CHAIN_CCIP_SELECTOR);
        assertEq(_earningChainCcipAdapter.getChainSelector(EARNING_CHAIN_ID), 0);
    }

    function test_getChainId_AccountingChain() public view {
        assertEq(_accountingChainCcipAdapter.getChainId(EARNING_CHAIN_CCIP_SELECTOR), EARNING_CHAIN_ID);
        assertEq(_accountingChainCcipAdapter.getChainId(ACCOUNTING_CHAIN_CCIP_SELECTOR), 0);
    }

    function test_getChainId_EarningChain() public view {
        assertEq(_earningChainCcipAdapter.getChainId(ACCOUNTING_CHAIN_CCIP_SELECTOR), ACCOUNTING_CHAIN_ID);
        assertEq(_earningChainCcipAdapter.getChainId(EARNING_CHAIN_CCIP_SELECTOR), 0);
    }

    function test_getDestinationChainAdapter_returnsSetAdapter(uint256 chainId, address adapter) public {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);
        vm.assume(chainId != 0 && chainId != block.chainid);
        vm.assume(adapter != address(0));

        assertEq(_accountingChainCcipAdapter.getDestinationChainAdapter(chainId), address(0));

        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setDestinationChainAdapter(chainId, adapter);

        assertEq(_accountingChainCcipAdapter.getDestinationChainAdapter(chainId), adapter);
    }

    function test_getDestinationChainAdapter_reflectsUpdate(uint256 chainId, address adapter1, address adapter2)
        public
    {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);
        vm.assume(chainId != 0 && chainId != block.chainid);
        vm.assume(adapter1 != address(0) && adapter2 != address(0));
        vm.assume(adapter1 != adapter2);

        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setDestinationChainAdapter(chainId, adapter1);
        assertEq(_accountingChainCcipAdapter.getDestinationChainAdapter(chainId), adapter1);

        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setDestinationChainAdapter(chainId, adapter2);
        assertEq(_accountingChainCcipAdapter.getDestinationChainAdapter(chainId), adapter2);
    }

    function test_getDestinationChainAdapter_returnsZeroForUnsetChain(uint256 chainId) public view {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);
        assertEq(_accountingChainCcipAdapter.getDestinationChainAdapter(chainId), address(0));
    }

    function test_supportsInterface() public view {
        assertTrue(_accountingChainCcipAdapter.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(_accountingChainCcipAdapter.supportsInterface(type(IERC165).interfaceId));
        assertTrue(_earningChainCcipAdapter.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(_earningChainCcipAdapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_rescueNative_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, uint256 amount)
        public
    {
        vm.assume(unauthorizedMsgSender != address(0));
        _mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(_accountingChainCcipAdapter), IRescuableNative.rescueNative.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableNative(address(_accountingChainCcipAdapter)).rescueNative(amount);
    }

    function test_rescueNative_getsExpectedAmountOfNativeToMsgSender(uint256 adapterBalance, uint256 amountToRescue)
        public
    {
        // Avoid fuzzing the msgSender address to avoid .call on precompiles and zero address.
        address msgSender = makeAddr("msgSender");

        adapterBalance = _boundNativeAmount(adapterBalance);
        amountToRescue = _boundNativeAmount(amountToRescue);
        vm.assume(adapterBalance >= amountToRescue);

        vm.deal(address(_accountingChainCcipAdapter), adapterBalance);
        vm.assume(address(msgSender).balance == 0);

        vm.expectEmit(true, true, true, true);
        emit IRescuableNative.NativeRescued(msgSender, amountToRescue);
        vm.prank(msgSender);
        IRescuableNative(address(_accountingChainCcipAdapter)).rescueNative(amountToRescue);

        assertEq(address(msgSender).balance, amountToRescue);
        assertEq(address(_accountingChainCcipAdapter).balance, adapterBalance - amountToRescue);
    }

    function test_setChainSelector_reverts_ifNotAuthorized(address operator) public {
        vm.assume(operator != everyRoleAccount);
        vm.assume(operator != address(0));
        _assumeNotProxyAdmin(operator, address(_accountingChainCcipAdapter));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_accountingChainCcipAdapter),
                bytes4(ICcipBridgeAdapter.setChainSelector.selector)
            ),
            abi.encode(false)
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _accountingChainCcipAdapter.setChainSelector(EARNING_CHAIN_ID, EARNING_CHAIN_CCIP_SELECTOR);

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                operator,
                address(_earningChainCcipAdapter),
                bytes4(ICcipBridgeAdapter.setChainSelector.selector)
            ),
            abi.encode(false)
        );
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, operator));
        _earningChainCcipAdapter.setChainSelector(ACCOUNTING_CHAIN_ID, ACCOUNTING_CHAIN_CCIP_SELECTOR);
    }

    function test_setChainSelector_emitsChainSelectorSet(uint256 chainId, uint64 ccipChainSelector) public {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);

        vm.expectEmit(true, true, true, true);
        emit ICcipBridgeAdapter.ChainSelectorSet(chainId, ccipChainSelector);
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setChainSelector(chainId, ccipChainSelector);
    }

    function test_setDestinationChainAdapter_emitsDestinationChainAdapterSet(uint256 chainId, address adapter) public {
        vm.assume(chainId != EARNING_CHAIN_ID && chainId != ACCOUNTING_CHAIN_ID);
        vm.assume(chainId != 0 && chainId != block.chainid);

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.DestinationChainAdapterSet(chainId, adapter);
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setDestinationChainAdapter(chainId, adapter);
    }

    function test_setDestinationChainAdapter_reverts_ifChainIdIsZero() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setDestinationChainAdapter(0, makeAddr("adapter"));
    }

    function test_setDestinationChainAdapter_reverts_ifChainIdIsSelf() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setDestinationChainAdapter(block.chainid, makeAddr("adapter"));
    }

    function test_publishMessageToChainWithFeePayer_withTokenBridgeFee(
        uint256 amountUsdt,
        address feePayer,
        uint256 feeAmount,
        uint256 gasLimit,
        bytes memory bridgedData,
        bytes memory extraParamsData
    ) public {
        // Context: Accounting Chain -> Earning Chain

        vm.assume(feePayer != address(0));

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        address feeToken = address(_mockGho);
        feeAmount = _boundAssetAmount(feeToken, feeAmount);

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _mockTransferHelper.mockAsset(address(_mockGho), feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: extraParamsData
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: bridgedData,
            tokenAmounts: ccipTokenAmounts,
            feeToken: feeToken,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            )
        });

        {
            // Mock call to router.getFee - return the fee amount to avoid refund flow (this is tested in another test)
            vm.mockCall(
                address(_mockCCIPRouter),
                abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
                abi.encode(feeAmount)
            );

            // Expect a call to router to approve the bridged assets
            _expectBridgeAssetsApproval(ccipTokenAmounts);

            // Expect a call to router.ccipSend
            vm.expectCall(
                address(_mockCCIPRouter),
                0,
                abi.encodeCall(IRouterClient.ccipSend, (EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage))
            );
        }

        bytes32 messageId = keccak256("messageId");
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, messageId);
        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessagePublished(messageId);
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, bridgedData, bridgeParams
        );

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), 0);
        assertEq(_mockTransferHelper.getBalance(address(_mockGho)), 0);
    }

    function test_publishMessageToChainWithFeePayer_withNativeBridgeFee(
        uint256 amountUsdt,
        address feePayer,
        uint256 feeAmount,
        uint256 gasLimit,
        bytes memory bridgedData,
        bytes memory extraParamsData
    ) public {
        // Context: Accounting Chain -> Earning Chain

        vm.assume(feePayer != address(0));

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        address feeToken = address(0);
        feeAmount = _boundNativeAmount(feeAmount);

        // Airdrop assets to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockTransferHelper), feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: extraParamsData
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: bridgedData,
            tokenAmounts: ccipTokenAmounts,
            feeToken: feeToken,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            )
        });

        {
            // Mock call to router.getFee - return the fee amount to avoid refund flow (this is tested in another test)
            vm.mockCall(
                address(_mockCCIPRouter),
                abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
                abi.encode(feeAmount)
            );

            // Expect a call to router to approve the bridged assets
            _expectBridgeAssetsApproval(ccipTokenAmounts);

            // Expect a call to router.ccipSend
            vm.expectCall(
                address(_mockCCIPRouter),
                feeAmount,
                abi.encodeCall(IRouterClient.ccipSend, (EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage))
            );
        }

        bytes32 messageId = keccak256("messageId");
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, messageId);
        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessagePublished(messageId);
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, bridgedData, bridgeParams
        );

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), 0);
    }

    function test_publishMessageToChainWithFeePayer_withTokenBridgeFeeAndRefund(
        uint256 amountUsdt,
        address feePayer,
        uint256 feeAmount,
        uint256 gasLimit,
        bytes memory bridgedData,
        bytes memory extraParamsData
    ) public {
        // Context: Accounting Chain -> Earning Chain

        vm.assume(feePayer != address(0));
        vm.assume(feePayer != address(_mockTransferHelper));
        vm.assume(feePayer != address(_accountingChainCcipAdapter));

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        address feeToken = address(_mockGho);
        feeAmount = _boundAssetAmount(feeToken, feeAmount);
        vm.assume(feeAmount > 1);
        uint256 expectedFeeRefund = 1;
        uint256 actualFeeAmount = feeAmount - expectedFeeRefund;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _mockTransferHelper.mockAsset(address(_mockGho), feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: extraParamsData
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: bridgedData,
            tokenAmounts: ccipTokenAmounts,
            feeToken: feeToken,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            )
        });

        {
            // Mock call to router.getFee - return the fee amount to trigger refund flow
            vm.mockCall(
                address(_mockCCIPRouter),
                abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
                abi.encode(actualFeeAmount)
            );

            // Expect a call to router to approve the bridged assets
            _expectBridgeAssetsApproval(ccipTokenAmounts);

            // Expect a call to router.ccipSend
            vm.expectCall(
                address(_mockCCIPRouter),
                0,
                abi.encodeCall(IRouterClient.ccipSend, (EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage))
            );
        }

        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, bridgedData, bridgeParams
        );

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), 0);
        assertEq(_mockTransferHelper.getBalance(address(_mockGho)), 0);
        assertEq(_mockGho.balanceOf(address(feePayer)), expectedFeeRefund);
    }

    function test_publishMessageToChainWithFeePayer_withNativeBridgeFeeAndRefund(
        uint256 amountUsdt,
        address payable feePayer,
        uint256 feeAmount,
        uint256 gasLimit
    ) public {
        // Context: Accounting Chain -> Earning Chain

        vm.assume(feePayer != address(0));
        // Avoid sending to contracts in the system that may not have payable fallback
        vm.assume(feePayer.code.length == 0);
        // Exclude precompile addresses
        vm.assume(uint160(address(feePayer)) > 0xff);
        // Exclude console address
        vm.assume(feePayer != address(0x000000000000000000636F6e736F6c652e6c6f67));

        uint256 feePayerBalance = address(feePayer).balance;

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        feeAmount = _boundNativeAmount(feeAmount);
        vm.assume(feeAmount > 1);
        uint256 actualFeeAmount = feeAmount - 1; // expectedFeeRefund = 1

        // Airdrop assets to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockTransferHelper), feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: address(0),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: ""
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            )
        });

        {
            // Mock call to router.getFee - return the fee amount to avoid refund flow (this is tested in another test)
            vm.mockCall(
                address(_mockCCIPRouter),
                abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
                abi.encode(actualFeeAmount)
            );

            // Expect a call to router to approve the bridged assets
            _expectBridgeAssetsApproval(ccipTokenAmounts);

            // Expect a call to router.ccipSend
            vm.expectCall(
                address(_mockCCIPRouter),
                actualFeeAmount,
                abi.encodeCall(IRouterClient.ccipSend, (EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage))
            );
        }

        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", bridgeParams
        );

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), 0);
        assertEq(address(feePayer).balance, feePayerBalance + 1); // expectedFeeRefund = 1
    }

    function test_publishMessageToChainWithFeePayer_nativeFeeRefundSucceeds_eoaFeePayer(uint256 excessFee) public {
        excessFee = _boundNativeAmount(excessFee);
        uint256 amountUsdt = 100_000000; // 100 USDT

        address feePayer = makeAddr("eoaFeePayer");
        uint256 feePayerBalance = address(feePayer).balance;

        uint256 estimatedFeeAmount = 1 ether;
        uint256 allocatedFeeAmount = estimatedFeeAmount + excessFee;

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockTransferHelper), allocatedFeeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: address(0),
            feeAmount: allocatedFeeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
            abi.encode(estimatedFeeAmount)
        );
        _expectBridgeAssetsApproval(ccipTokenAmounts);
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", bridgeParams
        );

        assertEq(address(feePayer).balance, feePayerBalance + excessFee);
    }

    function test_publishMessageToChainWithFeePayer_nativeFeeRefundSucceeds_gasHeavyContractFeePayer(uint256 excessFee)
        public
    {
        excessFee = _boundNativeAmount(excessFee);
        uint256 amountUsdt = 100_000000; // 100 USDT

        MockGasHeavyReceiver gasHeavyFeePayer = new MockGasHeavyReceiver();

        uint256 estimatedFeeAmount = 1 ether;
        uint256 allocatedFeeAmount = estimatedFeeAmount + excessFee;

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockTransferHelper), allocatedFeeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(gasHeavyFeePayer),
            feeToken: address(0),
            feeAmount: allocatedFeeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
            abi.encode(estimatedFeeAmount)
        );
        _expectBridgeAssetsApproval(ccipTokenAmounts);
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", bridgeParams
        );

        assertEq(address(gasHeavyFeePayer).balance, excessFee);
        assertEq(gasHeavyFeePayer.receivedCount(), 1);
        assertEq(gasHeavyFeePayer.lastValue(), excessFee);
    }

    function test_publishMessageToChainWithFeePayer_refundThresholdWorksAsExpected_TokenBridgeFee(
        address feePayer,
        uint256 feeAmount,
        uint256 feeRefundThreshold,
        uint256 actualFeeAmount
    ) public {
        // Context: Accounting Chain -> Earning Chain

        vm.assume(feePayer != address(0));
        vm.assume(feePayer != address(_mockTransferHelper));
        vm.assume(feePayer != address(_accountingChainCcipAdapter));

        uint256 amountUsdt = 100_000000; // 100 USDT

        address feeToken = address(_mockGho);
        feeAmount = _boundAssetAmount(feeToken, feeAmount);
        feeRefundThreshold = _boundAssetAmount(feeToken, feeRefundThreshold);
        actualFeeAmount = _boundAssetAmount(feeToken, actualFeeAmount);

        vm.assume(feeAmount >= actualFeeAmount);

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _mockTransferHelper.mockAsset(address(_mockGho), feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: feeRefundThreshold,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: feeToken,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        {
            // Mock call to router.getFee - return the fee amount to trigger refund flow
            vm.mockCall(
                address(_mockCCIPRouter),
                abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
                abi.encode(actualFeeAmount)
            );

            // Expect a call to router to approve the bridged assets
            _expectBridgeAssetsApproval(ccipTokenAmounts);

            // Expect a call to router.ccipSend
            vm.expectCall(
                address(_mockCCIPRouter),
                0,
                abi.encodeCall(IRouterClient.ccipSend, (EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage))
            );
        }

        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", bridgeParams
        );

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), 0);
        assertEq(_mockTransferHelper.getBalance(address(_mockGho)), 0);

        // We already assumed that feeAmount >= actualFeeAmount, so we can safely subtract them to get the excess fee
        uint256 excessFee = feeAmount - actualFeeAmount;

        uint256 expectedFeeRefund;
        if (excessFee > feeRefundThreshold) {
            expectedFeeRefund = excessFee;
        } else {
            // If the excess fee is less than the refund threshold, no refund is triggered nor expected
            expectedFeeRefund = 0;
        }

        assertEq(_mockGho.balanceOf(bridgeParams.feePayer), expectedFeeRefund);
    }

    function test_publishMessageToChainWithFeePayer_refundThresholdWorksAsExpected_NativeBridgeFee(
        address feePayer,
        uint256 feeAmount,
        uint256 feeRefundThreshold,
        uint256 actualFeeAmount
    ) public {
        // Context: Accounting Chain -> Earning Chain

        vm.assume(feePayer != address(0));
        // Avoid sending to contracts in the system that may not have payable fallback
        vm.assume(feePayer.code.length == 0);
        // Exclude precompile addresses
        vm.assume(uint160(address(feePayer)) > 0xff);
        // Exclude console address
        vm.assume(feePayer != address(0x000000000000000000636F6e736F6c652e6c6f67));
        vm.assume(feePayer.balance == 0);
        vm.assume(feePayer != address(0));
        vm.assume(feePayer != address(_mockTransferHelper));
        vm.assume(feePayer != address(_accountingChainCcipAdapter));

        uint256 amountUsdt = 100_000000; // 100 USDT

        address feeToken = address(0);
        feeAmount = _boundNativeAmount(feeAmount);
        feeRefundThreshold = _boundNativeAmount(feeRefundThreshold);
        actualFeeAmount = _boundNativeAmount(actualFeeAmount);

        vm.assume(feeAmount >= actualFeeAmount);

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockTransferHelper), feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: feeRefundThreshold,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: feeToken,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        {
            // Mock call to router.getFee - return the fee amount to trigger refund flow
            vm.mockCall(
                address(_mockCCIPRouter),
                abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
                abi.encode(actualFeeAmount)
            );

            // Expect a call to router to approve the bridged assets
            _expectBridgeAssetsApproval(ccipTokenAmounts);

            // Expect a call to router.ccipSend
            vm.expectCall(
                address(_mockCCIPRouter),
                actualFeeAmount,
                abi.encodeCall(IRouterClient.ccipSend, (EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage))
            );
        }

        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", bridgeParams
        );

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), 0);

        // We already assumed that feeAmount >= actualFeeAmount, so we can safely subtract them to get the excess fee
        uint256 excessFee = feeAmount - actualFeeAmount;

        uint256 expectedFeeRefund;
        if (excessFee > feeRefundThreshold) {
            expectedFeeRefund = excessFee;
        } else {
            // If the excess fee is less than the refund threshold, no refund is triggered nor expected
            expectedFeeRefund = 0;
        }

        assertEq(address(feePayer).balance, expectedFeeRefund);
    }

    function test_publishMessageToChainWithFeePayer_dataOnlyMessage_withTokenBridgeFee(uint256 feeAmount) public {
        feeAmount = _boundAssetAmount(address(_mockGho), feeAmount);

        bytes memory arbitraryData = abi.encode(keccak256(hex"c0ffee"));

        // Only fee token should be pulled, not any bridged asset
        _mockTransferHelper.mockAsset(address(_mockGho), feeAmount);

        // Should create message with empty tokenAmounts array
        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: arbitraryData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(_mockGho),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockGho),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        vm.expectCall(
            address(_mockCCIPRouter),
            0,
            abi.encodeCall(IRouterClient.ccipSend, (EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage))
        );
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(0), 0, arbitraryData, bridgeParams
        );
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifNativeFeeIsBelowEstimate() public {
        uint256 idleNativeAssetAmount = 123;
        uint256 actualFeeAmount = 100;

        // Airdrop the fee amount into the adapter to make sure it can not be used.
        vm.deal(address(_accountingChainCcipAdapter), idleNativeAssetAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(0),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        // Mock call to router.getFee - return the fee amount to trigger refund flow
        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
            abi.encode(actualFeeAmount)
        );
        // Stub the call to router.ccipSend
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));

        vm.expectRevert(Errors.InsufficientFunds.selector);
        vm.prank(address(_mockAccountingChainGateway));
        // Do not send any native asset with the call to try using the idle funds on the adapter.
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, address(0), 0, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifOnlyGateway(address caller) public {
        vm.assume(caller != address(_mockAccountingChainGateway));
        vm.assume(caller != address(_mockEarningChainGateway));

        vm.prank(caller);
        vm.expectRevert(Errors.OnlyGateway.selector);
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID,
            address(0),
            0,
            "",
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: 0,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: ""
            })
        );

        vm.prank(caller);
        vm.expectRevert(Errors.OnlyGateway.selector);
        _earningChainCcipAdapter.publishMessageToChainWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            address(0),
            0,
            "",
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: 0,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: ""
            })
        );
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifDestinationChainAdapterNotSet(uint256 destinationChainId)
        public
    {
        vm.assume(destinationChainId != EARNING_CHAIN_ID);
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            destinationChainId,
            address(0),
            0,
            "",
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: 0,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: ""
            })
        );
    }

    function test_ccipReceive_arbitraryDataPassedToGateway() public {
        bytes memory arbitraryData = abi.encode(keccak256(hex"c0ffee"));

        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (EARNING_CHAIN_ID, address(0), 0, arbitraryData))
        );

        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
                sender: abi.encode(address(_earningChainCcipAdapter)),
                data: arbitraryData,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        vm.expectCall(
            address(_mockEarningChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (ACCOUNTING_CHAIN_ID, address(0), 0, arbitraryData))
        );

        vm.prank(address(_mockCCIPRouter));
        _earningChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: ACCOUNTING_CHAIN_CCIP_SELECTOR,
                sender: abi.encode(address(_accountingChainCcipAdapter)),
                data: arbitraryData,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function test_ccipReceive_handlesFundsReceived(uint256 amountUsdt, uint256 amountGho) public {
        // Context: Earning Chain -> Accounting Chain

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmount(address(_mockGho), amountGho);

        // Mint to adapter to mimic bridged funds
        _mockUsdt.mint(address(_accountingChainCcipAdapter), amountUsdt);
        _mockGho.mint(address(_accountingChainCcipAdapter), amountGho);

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](2);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});
        ccipTokenAmounts[1] = Client.EVMTokenAmount({token: address(_mockGho), amount: amountGho});

        // receiveMessage is called once per asset
        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, address(_mockUsdt), amountUsdt, ""))
        );
        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, address(_mockGho), amountGho, ""))
        );

        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
                sender: abi.encode(address(_earningChainCcipAdapter)),
                data: "",
                destTokenAmounts: ccipTokenAmounts
            })
        );
    }

    function test_ccipReceive_emitsMessageId() public {
        // Context: Earning Chain -> Accounting Chain

        uint256 amountUsdt = 123 * 10 ** 6;
        uint256 amountGho = 456 * 10 ** 18;

        // Mint to adapter to mimic bridged funds
        _mockUsdt.mint(address(_accountingChainCcipAdapter), amountUsdt);
        _mockGho.mint(address(_accountingChainCcipAdapter), amountGho);

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](2);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});
        ccipTokenAmounts[1] = Client.EVMTokenAmount({token: address(_mockGho), amount: amountGho});

        // receiveMessage is called once per asset
        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, address(_mockUsdt), amountUsdt, ""))
        );
        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, address(_mockGho), amountGho, ""))
        );

        bytes32 messageId = keccak256("messageId");

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessageReceived(messageId);
        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: messageId,
                sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
                sender: abi.encode(address(_earningChainCcipAdapter)),
                data: "",
                destTokenAmounts: ccipTokenAmounts
            })
        );
    }

    function test_ccipReceive_handlesBothAssetsAndMessageData(uint256 amountUsdt, uint256 amountGho) public {
        // Context: Earning Chain -> Accounting Chain

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmount(address(_mockGho), amountGho);

        bytes memory arbitraryData = abi.encode(keccak256(hex"c0ffee"));

        // Mint to adapter to mimic bridged funds
        _mockUsdt.mint(address(_accountingChainCcipAdapter), amountUsdt);
        _mockGho.mint(address(_accountingChainCcipAdapter), amountGho);

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](2);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});
        ccipTokenAmounts[1] = Client.EVMTokenAmount({token: address(_mockGho), amount: amountGho});

        // Expect both assets and message data to be passed to gateway in separate calls
        // Assets are processed one at a time
        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, address(_mockUsdt), amountUsdt, ""))
        );
        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, address(_mockGho), amountGho, ""))
        );
        // Message data is passed separately
        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (EARNING_CHAIN_ID, address(0), 0, arbitraryData))
        );

        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
                sender: abi.encode(address(_earningChainCcipAdapter)),
                data: arbitraryData,
                destTokenAmounts: ccipTokenAmounts
            })
        );
    }

    function test_ccipReceive_reverts_ifFundsHandlingFails(uint256 amountUsdt, uint256 amountGho) public {
        // Context: Earning Chain -> Accounting Chain

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmount(address(_mockGho), amountGho);

        _mockUsdt.mint(address(_accountingChainCcipAdapter), amountUsdt);
        _mockGho.mint(address(_accountingChainCcipAdapter), amountGho);

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](2);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});
        ccipTokenAmounts[1] = Client.EVMTokenAmount({token: address(_mockGho), amount: amountGho});

        bytes32 messageId = keccak256("messageId");
        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(_earningChainCcipAdapter)),
            data: "",
            destTokenAmounts: ccipTokenAmounts
        });

        // mock a revert from downstream fund handling (first asset)
        // e.g. deposit of asset into Allocator is disabled
        vm.mockCallRevert(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, address(_mockUsdt), amountUsdt, "")),
            abi.encodeWithSelector(Errors.InvalidParameter.selector, "test")
        );

        vm.prank(address(_mockCCIPRouter));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector, "test"));
        _accountingChainCcipAdapter.ccipReceive(ccipMessage);
    }

    function test_ccipReceive_reverts_ifOnlyDestinationChainAdapter(address sender) public {
        vm.assume(sender != address(_earningChainCcipAdapter));
        vm.expectRevert(IBridgeAdapter.OnlyDestinationChainAdapter.selector);
        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
                sender: abi.encode(sender),
                data: abi.encode(keccak256(hex"c0ffee")),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function test_ccipReceive_reverts_ifNotRouter(address caller) public {
        vm.assume(caller != address(_mockCCIPRouter));
        vm.prank(caller);
        vm.expectRevert(IBridgeAdapter.OnlyBridgeRouter.selector);
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
                sender: abi.encode(address(0)),
                data: "",
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function test_ccipReceive_reverts_ifSenderDataLengthIsNotEvmAddressLength(bytes memory appendedData) public {
        vm.assume(appendedData.length > 0);

        bytes memory encodedSenderWithExtraBytes = abi.encodePacked(abi.encode(_earningChainCcipAdapter), appendedData);

        vm.expectRevert(ICcipBridgeAdapter.UnexpectedDataLength.selector);
        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
                sender: encodedSenderWithExtraBytes,
                data: abi.encode(keccak256(hex"c0ffee")),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function test_ccipReceive_reverts_ifSenderDataIsDirty() public {
        // This is equivalent to abi.encode(_earningChainCcipAdapter) and then making some bits a bit dirty.
        bytes memory encodedSenderWithExtraBytes =
            abi.encodePacked(hex"101000000000000000000000", _earningChainCcipAdapter);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
                sender: encodedSenderWithExtraBytes,
                data: abi.encode(keccak256(hex"c0ffee")),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function test_ccipReceive_reverts_ifDestinationChainAdapterNotSetForSourceChain(uint64 unknownChainSelector)
        public
    {
        // Use a chain selector that doesn't have a destination adapter configured
        vm.assume(unknownChainSelector != EARNING_CHAIN_CCIP_SELECTOR);
        vm.assume(unknownChainSelector != ACCOUNTING_CHAIN_CCIP_SELECTOR);
        vm.assume(unknownChainSelector != 0);

        bytes memory arbitraryData = abi.encode(keccak256(hex"c0ffee"));

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: unknownChainSelector,
                sender: abi.encode(makeAddr("anySender")),
                data: arbitraryData,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function test_ccipReceive_reverts_ifChainSelectorMismatch() public {
        // This test covers the require that validates:
        // message.sourceChainSelector == _chainSelectorOf[chainIdFromMessageChainSelector]
        //
        // Create an inconsistent state by setting a new chain selector for an existing chain ID.
        // The old selector's reverse mapping (_chainIdOf) still points to the chain ID, but
        // the chain ID now maps to a different selector.

        uint64 staleChainSelector = 999;
        uint64 newChainSelector = 888;
        uint256 testChainId = 42;

        // First, set up a chain with selector 999
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setChainSelector(testChainId, staleChainSelector);

        // Set a destination adapter for this chain
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setDestinationChainAdapter(testChainId, makeAddr("someAdapter"));

        // Now update the chain to use a different selector (888)
        // This overwrites _chainSelectorOf[testChainId] = 888
        // But _chainIdOf[999] still equals testChainId (stale mapping)
        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.setChainSelector(testChainId, newChainSelector);

        bytes memory arbitraryData = abi.encode(keccak256(hex"c0ffee"));

        // Try to receive a message using the stale selector (999)
        // _chainIdOf[999] = testChainId (still exists)
        // _destinationChainAdapterOf[testChainId] = someAdapter (passes first check)
        // _chainSelectorOf[testChainId] = 888 != 999 (fails second check)
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(address(_mockCCIPRouter));
        _accountingChainCcipAdapter.ccipReceive(
            Client.Any2EVMMessage({
                messageId: 0,
                sourceChainSelector: staleChainSelector,
                sender: abi.encode(makeAddr("someAdapter")),
                data: arbitraryData,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function test_ccipReceive_revertsWhenReentrancyOccurs() public {
        // Deploy a malicious gateway that attempts reentrancy via ccipReceive
        MockReentrantGateway maliciousGateway = new MockReentrantGateway(address(_mockTransferHelper));

        // Deploy a new adapter with the malicious gateway
        CcipAdapter adapterWithMaliciousGateway = _deployCcipAdapter(
            address(_mockAccessManager),
            address(maliciousGateway),
            address(_mockCCIPRouter),
            address(_mockTransferHelper)
        );

        // Set up chain selectors and destination adapters
        vm.prank(everyRoleAccount);
        adapterWithMaliciousGateway.setChainSelector(EARNING_CHAIN_ID, EARNING_CHAIN_CCIP_SELECTOR);
        vm.prank(everyRoleAccount);
        adapterWithMaliciousGateway.setDestinationChainAdapter(EARNING_CHAIN_ID, address(_earningChainCcipAdapter));

        bytes32 messageId = keccak256("reentrancyTest");
        bytes memory arbitraryData = abi.encode(keccak256(hex"c0ffee"));

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(_earningChainCcipAdapter)),
            data: arbitraryData,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        // Configure the malicious gateway to attempt reentrancy by calling ccipReceive again
        maliciousGateway.setReentrancyTargetCcipReceive(address(adapterWithMaliciousGateway), ccipMessage);

        // The reentrancy is blocked by the nonReentrant modifier.
        // Flow:
        // 1. Enter ccipReceive (sets reentrancy lock via nonReentrant)
        // 2. Call _processMessage -> gateway.receiveMessage
        // 3. Gateway attempts to re-enter ccipReceive (in theory this re-entrancy can be further downstream)
        // 4. Reentrancy guard reverts with ReentrancyGuardReentrantCall
        // 5. Revert bubbles up, entire transaction reverts

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(address(_mockCCIPRouter));
        adapterWithMaliciousGateway.ccipReceive(ccipMessage);
    }

    function test_publishMessageToChainWithFeePayer_resetsAdapterToRouterAllowanceToZero_FeeTokenNotBeingBridged(
        uint256 amountGho,
        address feePayer,
        uint256 feeAmount,
        uint256 gasLimit
    ) public {
        vm.assume(feePayer != address(0));
        vm.assume(feePayer != address(_mockTransferHelper));
        vm.assume(feePayer != address(_accountingChainCcipAdapter));

        amountGho = _boundAssetAmount(address(_mockGho), amountGho);

        // Use USDT as fee token (different from bridged asset to isolate fee token allowance behavior)
        address feeToken = address(_mockUsdt);
        feeAmount = _boundAssetAmount(feeToken, feeAmount);
        gasLimit = bound(gasLimit, 200_000, 500_000);

        // Airdrop tokens to the TransferHelper
        _mockTransferHelper.mockAsset(address(_mockGho), amountGho);
        _mockTransferHelper.mockAsset(address(_mockUsdt), feeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: ""
        });

        // Route messages back into the local test environment and use a real router fee pull.
        _mockCCIPRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        _mockCCIPRouter.setFee(feeAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockGho), amountGho, "", bridgeParams
        );

        // Verify allowance is reset to 0 after the send
        uint256 remainingAllowance = _mockUsdt.allowance(address(_accountingChainCcipAdapter), address(_mockCCIPRouter));
        assertEq(remainingAllowance, 0, "Fee token allowance should be reset to 0 after send");
    }

    function test_publishMessageToChainWithFeePayer_resetsAdapterToRouterAllowanceToZero_FeeTokenBeingBridged(
        uint256 amountUsdt,
        address feePayer,
        uint256 feeAmount,
        uint256 gasLimit
    ) public {
        vm.assume(feePayer != address(0));
        vm.assume(feePayer != address(_mockTransferHelper));
        vm.assume(feePayer != address(_accountingChainCcipAdapter));

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        // Use USDT as both bridged asset AND fee token
        address feeToken = address(_mockUsdt);
        feeAmount = _boundAssetAmount(feeToken, feeAmount);
        gasLimit = bound(gasLimit, 200_000, 500_000);

        uint256 totalUsdtAmount = amountUsdt + feeAmount;

        // Airdrop tokens to the TransferHelper
        _mockTransferHelper.mockAsset(address(_mockUsdt), totalUsdtAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: ""
        });

        // Route messages back into the local test environment and use a real router fee pull.
        _mockCCIPRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        _mockCCIPRouter.setFee(feeAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", bridgeParams
        );

        // Verify allowance is reset to 0 after the send (even when fee token matches bridged asset)
        uint256 remainingAllowance = _mockUsdt.allowance(address(_accountingChainCcipAdapter), address(_mockCCIPRouter));
        assertEq(remainingAllowance, 0, "Fee token allowance should be reset to 0 even when matching bridged asset");
    }

    function test_publishMessageToChainWithFeePayer_stuckFundsCannotBeUsedToCoverBridgeFees() public {
        uint256 stuckAmount = 100 * 10 ** 6; // 100 USDC stuck in adapter
        uint256 amountGho = 50 * 10 ** 18; // 50 GHO to bridge
        address attacker = makeAddr("attacker");

        // Simulate stuck funds in adapter (from a failed ccipReceive)
        _mockUsdt.mint(address(_accountingChainCcipAdapter), stuckAmount);

        // Verify adapter has no allowance to router
        uint256 initialAllowance = _mockUsdt.allowance(address(_accountingChainCcipAdapter), address(_mockCCIPRouter));
        assertEq(initialAllowance, 0, "Initial allowance should be 0");

        // Prepare a legitimate bridge operation with USDT fee to verify allowance reset
        // Airdrop GHO to TransferHelper for bridging
        _mockTransferHelper.mockAsset(address(_mockGho), amountGho);

        // Do a bridge with USDT fee to "create" allowance and then verify it gets reset
        uint256 legitimateFeeAmount = 10 * 10 ** 6; // 10 USDT
        _mockTransferHelper.mockAsset(address(_mockUsdt), legitimateFeeAmount);

        uint256 adapterBalanceBeforeBridge = _mockUsdt.balanceOf(address(_accountingChainCcipAdapter));

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: attacker,
            feeToken: address(_mockUsdt),
            feeAmount: legitimateFeeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        // Route messages back into the local test environment and use a real router fee pull.
        _mockCCIPRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        _mockCCIPRouter.setFee(legitimateFeeAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockGho), amountGho, "", bridgeParams
        );

        // Verify allowance is 0 after the bridge. This prevents the attack where stuck funds could be used via leftover
        // allowance
        uint256 postBridgeAllowance =
            _mockUsdt.allowance(address(_accountingChainCcipAdapter), address(_mockCCIPRouter));
        assertEq(
            postBridgeAllowance, 0, "Allowance should be reset to 0 after bridge - this prevents fee subsidy attack"
        );

        // Verify the original stuck funds are still in the adapter and cannot be consumed by fee pull.
        uint256 adapterBalanceAfterBridge = _mockUsdt.balanceOf(address(_accountingChainCcipAdapter));
        assertEq(
            adapterBalanceAfterBridge,
            adapterBalanceBeforeBridge,
            "Original stuck funds should not be consumed by the bridge"
        );
    }

    function test_publishMessageToChainWithFeePayer_allowanceResetPreventsSubsequentFreeBridgingByPassingZeroFee()
        public
    {
        uint256 stuckAmount = 100 * 10 ** 6; // 100 USDC
        uint256 amountGho = 50 * 10 ** 18; // 50 GHO to bridge
        address feePayer = makeAddr("feePayer");

        // Simulate stuck funds from failed ccipReceive
        _mockUsdt.mint(address(_accountingChainCcipAdapter), stuckAmount);

        uint256 adapterBalanceBeforeBridge = _mockUsdt.balanceOf(address(_accountingChainCcipAdapter));

        // Simulate a legitimate bridge call that overpays fees
        uint256 allocatedFeeAmount = 50 * 10 ** 6; // 50 USDC allocated
        uint256 actualFeeAmount = 25 * 10 ** 6; // Only 25 USDC needed (simulates overpayment)
        uint256 refundAmount = allocatedFeeAmount - actualFeeAmount; // 25 USDC refund

        _mockTransferHelper.mockAsset(address(_mockGho), amountGho);
        _mockTransferHelper.mockAsset(address(_mockUsdt), allocatedFeeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: address(_mockUsdt),
            feeAmount: allocatedFeeAmount,
            feeRefundThreshold: 0, // Refund any excess
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        // Route messages back into the local test environment and use a real router fee pull.
        _mockCCIPRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        _mockCCIPRouter.setFee(actualFeeAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockGho), amountGho, "", bridgeParams
        );

        // Allowance should be 0, otherwise the allowance would remain at allocatedFeeAmount, allowing an attacker
        // to call publishMessageToChainWithFeePayer with feeAmount=0 and have the router use the stuck funds via the
        // leftover allowance.
        uint256 routerAllowance = _mockUsdt.allowance(address(_accountingChainCcipAdapter), address(_mockCCIPRouter));
        assertEq(
            routerAllowance,
            0,
            "Router allowance should be reset to 0 after overpaid bridge - this prevents fee subsidy attack"
        );

        // Verify refund was sent to feePayer
        assertEq(_mockUsdt.balanceOf(feePayer), refundAmount, "Fee payer should receive the refund");

        // Verify the original stuck funds are still in the adapter (not consumed by the bridge).
        uint256 expectedAdapterBalance = adapterBalanceBeforeBridge;
        assertEq(
            _mockUsdt.balanceOf(address(_accountingChainCcipAdapter)),
            expectedAdapterBalance,
            "Adapter should only retain originally stuck funds"
        );
    }

    function test_publishMessageToChainWithFeePayer_nativeFeesDoNotAffectTokenAllowance() public {
        uint256 stuckUsdt = 100 * 10 ** 6; // 100 USDT stuck
        uint256 amountGho = 50 * 10 ** 18;
        uint256 nativeFeeAmount = 1 ether;
        address feePayer = makeAddr("feePayer");

        // Stuck USDT in adapter
        _mockUsdt.mint(address(_accountingChainCcipAdapter), stuckUsdt);

        // Prepare native fee bridge
        _mockTransferHelper.mockAsset(address(_mockGho), amountGho);
        vm.deal(address(_mockTransferHelper), nativeFeeAmount);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: address(0), // Native currency
            feeAmount: nativeFeeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockGho), amount: amountGho});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
            abi.encode(nativeFeeAmount)
        );

        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockGho), amountGho, "", bridgeParams
        );

        // Verify no USDT allowance was created (native fees shouldn't affect ERC20 allowances)
        uint256 usdtAllowance = _mockUsdt.allowance(address(_accountingChainCcipAdapter), address(_mockCCIPRouter));
        assertEq(usdtAllowance, 0, "Native fee bridge should not create any ERC20 allowance");

        // Verify stuck USDT is still protected
        assertEq(
            _mockUsdt.balanceOf(address(_accountingChainCcipAdapter)),
            stuckUsdt,
            "Stuck USDT should remain in adapter after native fee bridge"
        );
    }

    function test_replayFundsReceiving_processesStuckFunds(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        // Simulate stuck funds in adapter
        _mockUsdt.mint(address(_accountingChainCcipAdapter), amountUsdt);

        // Expect the gateway to receive the funds
        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, address(_mockUsdt), amountUsdt, ""))
        );

        vm.prank(everyRoleAccount);
        _accountingChainCcipAdapter.replayFundsReceiving(address(_mockUsdt), amountUsdt);
    }

    function test_replayFundsReceiving_reverts_ifNotAuthorized(address unauthorizedMsgSender) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _mockAccessManager.mockRejectCall(
            unauthorizedMsgSender,
            address(_accountingChainCcipAdapter),
            ICcipBridgeAdapter.replayFundsReceiving.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        _accountingChainCcipAdapter.replayFundsReceiving(address(_mockUsdt), 100);
    }

    function test_rescueTokens_rescuesUnregisteredToken(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        // _mockUsdt is NOT registered in the mock asset registry by default
        _mockUsdt.mint(address(_accountingChainCcipAdapter), amount);

        address msgSender = makeAddr("rescuer");

        vm.expectEmit(true, true, true, true);
        emit IRescuableToken.TokensRescued(address(_mockUsdt), msgSender, amount);
        vm.prank(msgSender);
        IRescuableToken(address(_accountingChainCcipAdapter)).rescueTokens(address(_mockUsdt), amount);

        assertEq(_mockUsdt.balanceOf(msgSender), amount);
        assertEq(_mockUsdt.balanceOf(address(_accountingChainCcipAdapter)), 0);
    }

    function test_rescueTokens_reverts_ifTokenIsRegistered(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);

        // Register the asset
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        _mockUsdt.mint(address(_accountingChainCcipAdapter), amount);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        IRescuableToken(address(_accountingChainCcipAdapter)).rescueTokens(address(_mockUsdt), amount);
    }

    function test_rescueTokens_reverts_ifNotAuthorized(address unauthorizedMsgSender) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(_accountingChainCcipAdapter), IRescuableToken.rescueTokens.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableToken(address(_accountingChainCcipAdapter)).rescueTokens(address(_mockUsdt), 100);
    }

    function _expectBridgeAssetsApproval(Client.EVMTokenAmount[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address asset = tokens[i].token;
            uint256 amount = tokens[i].amount;
            vm.expectCall(asset, abi.encodeCall(IERC20.approve, (address(_mockCCIPRouter), amount)));
        }
    }

    function _stubCcipRouterSend(uint64 chainSelector, Client.EVM2AnyMessage memory message, bytes32 messageId)
        internal
    {
        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.ccipSend.selector, chainSelector, message),
            abi.encode(messageId)
        );
    }
}
