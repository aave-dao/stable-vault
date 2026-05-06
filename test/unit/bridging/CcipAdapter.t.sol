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
import {Constants} from "src/types/Constants.sol";
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
import {MockRejectNativeReceiver} from "test/mocks/MockRejectNativeReceiver.sol";
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

    /// @dev CCIP encodes native fees as `address(0)` in `EVM2AnyMessage.feeToken`. Defined here (rather than imported
    /// from the adapter) so the test independently asserts CCIP's external convention.
    address internal constant CCIP_NATIVE_FEE_TOKEN = address(0);

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

    /// @dev Under the opaque-bytes dispatch shape the adapter owns bridge-fee staging: it pulls
    /// the feeToken from the feePayer via `safeTransferFrom`. Tests that previously pre-funded
    /// TransferHelper (simulating caller-layer staging) now mint the fee to the feePayer and set
    /// the approval on the adapter directly.
    function _stageTokenFeeFromPayer(address adapter, address feePayer, IMockErc20 feeToken, uint256 feeAmount)
        internal
    {
        feeToken.mint(feePayer, feeAmount);
        vm.prank(feePayer);
        // MockNonStandardErc20.approve returns no value — call through its non-standard interface
        // (direct IERC20.approve would fail on the return-value decode).
        MockNonStandardErc20(address(feeToken)).approve(adapter, feeAmount);
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        _deployCcipAdapter(
            address(_mockAccessManager), address(_mockAccountingChainGateway), address(_mockCCIPRouter), address(0)
        );
    }

    function test_constructor_reverts_ifInvalidCCIPRouter() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        _deployCcipAdapter(
            address(_mockAccessManager), address(_mockAccountingChainGateway), address(0), address(_mockTransferHelper)
        );
    }

    function test_constructor_reverts_ifInvalidAssetRegistry() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CcipAdapter(
            address(_mockAccessManager),
            address(_mockAccountingChainGateway),
            address(_mockCCIPRouter),
            address(_mockTransferHelper),
            address(0)
        );
    }

    function test_constructor_reverts_ifInvalidGateway() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CcipAdapter(
            address(_mockAccessManager),
            address(0),
            address(_mockCCIPRouter),
            address(_mockTransferHelper),
            address(_mockAssetRegistry)
        );
    }

    function test_nativeFeeTokenConstant_matchesCcipExpectedValueConvention() public pure {
        assertEq(CCIP_NATIVE_FEE_TOKEN, address(0));
    }

    function test_ccipFeeTokenHelper_translatesNativeToCcipSentinel() public pure {
        assertEq(_ccipFeeToken(Constants.NATIVE_CURRENCY), CCIP_NATIVE_FEE_TOKEN);
    }

    function test_ccipFeeTokenHelper_passesErc20Through(address erc20FeeToken) public pure {
        vm.assume(erc20FeeToken != Constants.NATIVE_CURRENCY);
        assertEq(_ccipFeeToken(erc20FeeToken), erc20FeeToken);
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

    function test_publishMessageToChainWithFeePayer_reverts_ifAdapterDataMalformed() public {
        vm.expectRevert();
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(0), 0, "", address(this), DEFAULT_GAS_LIMIT, hex"01"
        );
    }

    function test_publishMessageToChainWithFeePayer_withTokenBridgeFee(
        uint256 amountUsdt,
        address feePayer,
        uint256 feeAmount,
        uint256 gasLimit,
        bytes memory bridgedData
    ) public {
        // Context: Accounting Chain -> Earning Chain

        vm.assume(feePayer != address(0));

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        address feeToken = address(_mockGho);
        feeAmount = _boundAssetAmount(feeToken, feeAmount);

        // Airdrop bridged asset to the TransferHelper (pushed there by the Allocator); fee is
        // staged by the adapter via safeTransferFrom under the opaque-bytes dispatch shape.
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), feePayer, _mockGho, feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: 0})
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: bridgedData,
            tokenAmounts: ccipTokenAmounts,
            feeToken: _ccipFeeToken(feeToken),
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
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, bridgedData, feePayer, gasLimit, adapterData
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
        bytes memory bridgedData
    ) public {
        // Context: Accounting Chain -> Earning Chain

        vm.assume(feePayer != address(0));

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        address feeToken = Constants.NATIVE_CURRENCY;
        feeAmount = _boundNativeAmount(feeAmount);

        // Airdrop bridged asset to the TransferHelper (pushed there by the Allocator); native fee
        // is supplied via msg.value to the adapter under the opaque-bytes dispatch shape.
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockAccountingChainGateway), feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: 0})
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: bridgedData,
            tokenAmounts: ccipTokenAmounts,
            feeToken: _ccipFeeToken(feeToken),
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

        {
            bytes32 messageId = keccak256("messageId");
            _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, messageId);
            vm.expectEmit(true, true, true, true);
            emit IBridgeAdapter.MessagePublished(messageId);
        }
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: feeAmount}(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, bridgedData, feePayer, gasLimit, adapterData
        );

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), 0);
    }

    function test_publishMessageToChainWithFeePayer_pullsErc20FeeDirectlyFromFeePayer() public {
        // Regression: post round-trip removal, ERC-20 fee must move feePayer -> adapter via
        // safeTransferFrom, never through the TransferHelper.
        address feePayer = makeAddr("feePayerDirectPull");
        uint256 amountUsdt = 50_000000;
        uint256 feeAmount = 10 * 10 ** 18;

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), feePayer, _mockGho, feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({feeToken: address(_mockGho), feeAmount: feeAmount, feeRefundThreshold: 0})
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});
        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: address(_mockGho),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });
        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
            abi.encode(feeAmount)
        );
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(uint256(1)));

        // Direct pull: feePayer -> adapter (NOT feePayer -> TransferHelper).
        vm.expectCall(
            address(_mockGho),
            abi.encodeCall(IERC20.transferFrom, (feePayer, address(_accountingChainCcipAdapter), feeAmount))
        );

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", feePayer, DEFAULT_GAS_LIMIT, adapterData
        );

        // Fee never enters TransferHelper.
        assertEq(_mockTransferHelper.getBalance(address(_mockGho)), 0);
    }

    function test_publishMessageToChainWithFeePayer_nativeFeeNeverEntersTransferHelper() public {
        address payable feePayer = payable(makeAddr("feePayerNativeDirect"));
        uint256 amountUsdt = 100_000000;
        uint256 feeAmount = 1 ether;

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockAccountingChainGateway), feeAmount);
        uint256 thNativeBefore = address(_mockTransferHelper).balance;

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: feeAmount, feeRefundThreshold: 0
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});
        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: CCIP_NATIVE_FEE_TOKEN,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });
        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
            abi.encode(feeAmount)
        );
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(uint256(2)));

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: feeAmount}(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", feePayer, DEFAULT_GAS_LIMIT, adapterData
        );

        // TH native balance unchanged — fee never routed through the helper.
        assertEq(address(_mockTransferHelper).balance, thNativeBefore, "TH native balance changed");
    }

    function test_publishMessageToChainWithFeePayer_withTokenBridgeFeeAndRefund(
        uint256 amountUsdt,
        address feePayer,
        uint256 feeAmount,
        uint256 gasLimit,
        bytes memory bridgedData
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

        // Airdrop bridged asset to the TransferHelper (pushed there by the Allocator); fee is
        // staged by the adapter via safeTransferFrom under the opaque-bytes dispatch shape.
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), feePayer, _mockGho, feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: 0})
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: bridgedData,
            tokenAmounts: ccipTokenAmounts,
            feeToken: _ccipFeeToken(feeToken),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            )
        });

        {
            // Mock call to router.getFee - return the fee amount to trigger refund flow
            vm.mockCall(
                address(_mockCCIPRouter),
                abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
                abi.encode(feeAmount - expectedFeeRefund)
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
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, bridgedData, feePayer, gasLimit, adapterData
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

        // Airdrop bridged asset to the TransferHelper (pushed there by the Allocator); native fee
        // is supplied via msg.value to the adapter under the opaque-bytes dispatch shape.
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockAccountingChainGateway), feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: feeAmount, feeRefundThreshold: 0
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: CCIP_NATIVE_FEE_TOKEN,
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
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: feeAmount}(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", feePayer, gasLimit, adapterData
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
        vm.deal(address(_mockAccountingChainGateway), allocatedFeeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: allocatedFeeAmount, feeRefundThreshold: 0
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: CCIP_NATIVE_FEE_TOKEN,
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
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: allocatedFeeAmount}(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", feePayer, DEFAULT_GAS_LIMIT, adapterData
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
        vm.deal(address(_mockAccountingChainGateway), allocatedFeeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: allocatedFeeAmount, feeRefundThreshold: 0
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: CCIP_NATIVE_FEE_TOKEN,
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
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: allocatedFeeAmount}(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            "",
            address(gasHeavyFeePayer),
            DEFAULT_GAS_LIMIT,
            adapterData
        );

        assertEq(address(gasHeavyFeePayer).balance, excessFee);
        assertEq(gasHeavyFeePayer.receivedCount(), 1);
        assertEq(gasHeavyFeePayer.lastValue(), excessFee);
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifNativeFeeRefundFails() public {
        uint256 amountUsdt = 100_000000;
        uint256 estimatedFeeAmount = 1 ether;
        uint256 excessFee = 1 wei;
        uint256 allocatedFeeAmount = estimatedFeeAmount + excessFee;

        MockRejectNativeReceiver rejectingFeePayer = new MockRejectNativeReceiver();

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockAccountingChainGateway), allocatedFeeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: allocatedFeeAmount, feeRefundThreshold: 0
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: CCIP_NATIVE_FEE_TOKEN,
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

        vm.expectRevert(Errors.NativeTransferFailed.selector);
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: allocatedFeeAmount}(
            EARNING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            "",
            address(rejectingFeePayer),
            DEFAULT_GAS_LIMIT,
            adapterData
        );
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

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), feePayer, _mockGho, feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: feeRefundThreshold
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: _ccipFeeToken(feeToken),
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
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", feePayer, DEFAULT_GAS_LIMIT, adapterData
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

        assertEq(_mockGho.balanceOf(feePayer), expectedFeeRefund);
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

        address feeToken = Constants.NATIVE_CURRENCY;
        feeAmount = _boundNativeAmount(feeAmount);
        feeRefundThreshold = _boundNativeAmount(feeRefundThreshold);
        actualFeeAmount = _boundNativeAmount(actualFeeAmount);

        vm.assume(feeAmount >= actualFeeAmount);

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        vm.deal(address(_mockAccountingChainGateway), feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: feeRefundThreshold
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: _ccipFeeToken(feeToken),
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
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: feeAmount}(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", feePayer, DEFAULT_GAS_LIMIT, adapterData
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
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), everyRoleAccount, _mockGho, feeAmount);

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

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({feeToken: address(_mockGho), feeAmount: feeAmount, feeRefundThreshold: 0})
        );

        vm.expectCall(
            address(_mockCCIPRouter),
            0,
            abi.encodeCall(IRouterClient.ccipSend, (EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage))
        );
        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            arbitraryData,
            everyRoleAccount,
            DEFAULT_GAS_LIMIT,
            adapterData
        );
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifNativeFeeIsBelowEstimate() public {
        uint256 idleNativeAssetAmount = 123;
        uint256 actualFeeAmount = 100;

        // Airdrop the fee amount into the adapter to make sure it can not be used.
        vm.deal(address(_accountingChainCcipAdapter), idleNativeAssetAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({feeToken: Constants.NATIVE_CURRENCY, feeAmount: 0, feeRefundThreshold: 0})
        );

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: CCIP_NATIVE_FEE_TOKEN,
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
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, "", address(this), DEFAULT_GAS_LIMIT, adapterData
        );
    }

    function test_publishMessageToChainWithFeePayer_reverts_ifNativeMsgValueExceedsFeeAmountByOne() public {
        // The adapter enforces strict equality between msg.value and adapterData.feeAmount when the fee token is
        // native; sending one extra wei must revert rather than silently being absorbed by the adapter.
        // This is enforced to avoid an under-counted refund.
        uint256 feeAmount = 1 ether;

        vm.deal(address(_mockAccountingChainGateway), feeAmount + 1);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: Constants.NATIVE_CURRENCY, feeAmount: feeAmount, feeRefundThreshold: 0
            })
        );

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: CCIP_NATIVE_FEE_TOKEN,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        // Estimated fee matches feeAmount, so the first `feeAmount >= estimatedFeeAmount` check passes and the
        // strict-equality `msg.value == feeAmount` check is the one that reverts.
        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
            abi.encode(feeAmount)
        );

        vm.expectRevert(Errors.InsufficientFunds.selector);
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: feeAmount + 1}(
            EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, "", address(this), DEFAULT_GAS_LIMIT, adapterData
        );
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
            address(this),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.AdapterData({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: 0, feeRefundThreshold: 0
                })
            )
        );

        vm.prank(caller);
        vm.expectRevert(Errors.OnlyGateway.selector);
        _earningChainCcipAdapter.publishMessageToChainWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            address(0),
            0,
            "",
            address(this),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.AdapterData({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: 0, feeRefundThreshold: 0
                })
            )
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
            address(this),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.AdapterData({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: 0, feeRefundThreshold: 0
                })
            )
        );
    }

    function test_ccipReceive_arbitraryDataPassedToGateway() public {
        bytes memory arbitraryData = abi.encode(keccak256(hex"c0ffee"));

        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(
                IChainGateway.receiveMessage, (EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, arbitraryData)
            )
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
            abi.encodeCall(
                IChainGateway.receiveMessage,
                (ACCOUNTING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, arbitraryData)
            )
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

    function test_ccipReceive_handlesFundsReceived(uint256 amountUsdt) public {
        // Context: Earning Chain -> Accounting Chain

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        // Mint to adapter to mimic bridged funds
        _mockUsdt.mint(address(_accountingChainCcipAdapter), amountUsdt);

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, ""))
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

        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(
                IChainGateway.receiveMessage, (EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, "")
            )
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
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function test_ccipReceive_handlesFundsAndMessageData(uint256 amountUsdt) public {
        // Context: Earning Chain -> Accounting Chain

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        bytes memory arbitraryData = abi.encode(keccak256(hex"c0ffee"));

        // Mint to adapter to mimic bridged funds
        _mockUsdt.mint(address(_accountingChainCcipAdapter), amountUsdt);

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        vm.expectCall(
            address(_mockAccountingChainGateway),
            abi.encodeCall(
                IChainGateway.receiveMessage, (EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, arbitraryData)
            )
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

    function test_ccipReceive_reverts_ifFundsHandlingFails(uint256 amountUsdt) public {
        // Context: Earning Chain -> Accounting Chain

        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        _mockUsdt.mint(address(_accountingChainCcipAdapter), amountUsdt);

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

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
            abi.encodeCall(IChainGateway.receiveMessage, (EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "")),
            abi.encodeWithSelector(Errors.InvalidParameter.selector, "test")
        );

        vm.prank(address(_mockCCIPRouter));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector, "test"));
        _accountingChainCcipAdapter.ccipReceive(ccipMessage);
    }

    function test_ccipReceive_reverts_ifMoreThanOneTokenIsReceived(uint256 amountUsdt, uint256 amountGho) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmount(address(_mockGho), amountGho);

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](2);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});
        ccipTokenAmounts[1] = Client.EVMTokenAmount({token: address(_mockGho), amount: amountGho});

        vm.expectRevert(IBridgeAdapter.InvalidTokenCount.selector);
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

        _mockTransferHelper.mockAsset(address(_mockGho), amountGho);
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), feePayer, _mockUsdt, feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: 0})
        );

        // Route messages back into the local test environment and use a real router fee pull.
        _mockCCIPRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        _mockCCIPRouter.setFee(feeAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockGho), amountGho, "", feePayer, gasLimit, adapterData
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

        // Stage bridged amount in TransferHelper; stage fee via feePayer approval to adapter.
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), feePayer, _mockUsdt, feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: 0})
        );

        // Route messages back into the local test environment and use a real router fee pull.
        _mockCCIPRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        _mockCCIPRouter.setFee(feeAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", feePayer, gasLimit, adapterData
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
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), attacker, _mockUsdt, legitimateFeeAmount);

        uint256 adapterBalanceBeforeBridge = _mockUsdt.balanceOf(address(_accountingChainCcipAdapter));

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: address(_mockUsdt), feeAmount: legitimateFeeAmount, feeRefundThreshold: 0
            })
        );

        // Route messages back into the local test environment and use a real router fee pull.
        _mockCCIPRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        _mockCCIPRouter.setFee(legitimateFeeAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockGho), amountGho, "", attacker, DEFAULT_GAS_LIMIT, adapterData
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
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), feePayer, _mockUsdt, allocatedFeeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: address(_mockUsdt),
                feeAmount: allocatedFeeAmount,
                // Refund any excess.
                feeRefundThreshold: 0
            })
        );

        // Route messages back into the local test environment and use a real router fee pull.
        _mockCCIPRouter.setSourceChainSelector(EARNING_CHAIN_CCIP_SELECTOR, ACCOUNTING_CHAIN_CCIP_SELECTOR);
        _mockCCIPRouter.setFee(actualFeeAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockGho), amountGho, "", feePayer, DEFAULT_GAS_LIMIT, adapterData
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

        // Prepare native fee bridge: native fee flows via msg.value under the opaque-bytes shape.
        _mockTransferHelper.mockAsset(address(_mockGho), amountGho);
        vm.deal(address(_mockAccountingChainGateway), nativeFeeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: Constants.NATIVE_CURRENCY, // Native currency
                feeAmount: nativeFeeAmount,
                feeRefundThreshold: 0
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockGho), amount: amountGho});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: CCIP_NATIVE_FEE_TOKEN,
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
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer{value: nativeFeeAmount}(
            EARNING_CHAIN_ID, address(_mockGho), amountGho, "", feePayer, DEFAULT_GAS_LIMIT, adapterData
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

    function test_publishMessageToChainWithFeePayer_emitsFeeRefunded_whenExcessFeeExceedsThreshold() public {
        // Context: Accounting Chain -> Earning Chain

        address feePayer = makeAddr("feePayer");
        uint256 amountUsdt = 100_000000; // 100 USDT
        address feeToken = address(_mockGho);

        uint256 feeAmount = 10 ether; // fee allocated by the user
        uint256 actualFeeAmount = 7 ether; // fee estimated by the router
        uint256 feeRefundThreshold = 1 ether; // refund threshold
        // excessFee = 3 ether, which is > feeRefundThreshold (1 ether), so FeeRefunded should emit

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountUsdt);
        _stageTokenFeeFromPayer(address(_accountingChainCcipAdapter), feePayer, _mockGho, feeAmount);

        bytes memory adapterData = abi.encode(
            ICcipBridgeAdapter.AdapterData({
                feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: feeRefundThreshold
            })
        );

        Client.EVMTokenAmount[] memory ccipTokenAmounts = new Client.EVMTokenAmount[](1);
        ccipTokenAmounts[0] = Client.EVMTokenAmount({token: address(_mockUsdt), amount: amountUsdt});

        Client.EVM2AnyMessage memory expectedCcipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_earningChainCcipAdapter),
            data: "",
            tokenAmounts: ccipTokenAmounts,
            feeToken: _ccipFeeToken(feeToken),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        // Mock call to router.getFee - return actualFeeAmount so there is excess
        vm.mockCall(
            address(_mockCCIPRouter),
            abi.encodeWithSelector(IRouterClient.getFee.selector, EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage),
            abi.encode(actualFeeAmount)
        );

        _stubCcipRouterSend(EARNING_CHAIN_CCIP_SELECTOR, expectedCcipMessage, bytes32(0));

        uint256 expectedRefundAmount = feeAmount - actualFeeAmount; // 3 ether

        // Expect FeeRefunded event: feePayer (indexed), feeToken (indexed), amount
        vm.expectEmit(true, true, false, true);
        emit ICcipBridgeAdapter.FeeRefunded(feePayer, feeToken, expectedRefundAmount);

        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainCcipAdapter.publishMessageToChainWithFeePayer(
            EARNING_CHAIN_ID, address(_mockUsdt), amountUsdt, "", feePayer, DEFAULT_GAS_LIMIT, adapterData
        );
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

    /// @dev Mirrors the CcipAdapter's boundary translation: CCIP encodes native fees as `address(0)`.
    function _ccipFeeToken(address feeToken) internal pure returns (address) {
        return feeToken == Constants.NATIVE_CURRENCY ? CCIP_NATIVE_FEE_TOKEN : feeToken;
    }
}
