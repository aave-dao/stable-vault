// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {IWithdrawalExecutionPolicy} from "src/interfaces/IWithdrawalExecutionPolicy.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {PolicyRegistry} from "src/periphery/PolicyRegistry.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAllocator} from "test/mocks/MockAllocator.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";
import {MockBridgeAdapter} from "test/mocks/MockBridgeAdapter.sol";
import {MockDummyIouTokenManager} from "test/mocks/MockDummyIouTokenManager.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockReentrantErc20} from "test/mocks/MockReentrantErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract EarningChainGatewayTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant BURN_IOU_TOKEN_GAS_LIMIT = 120_000;
    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;
    uint256 internal DEFAULT_GAS_LIMIT = BURN_IOU_TOKEN_GAS_LIMIT;
    uint256 internal MAX_REDEMPTION_CAPACITY = type(uint128).max - 1;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    MockAccessManager internal _mockAccessManager;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    IMockErc20 internal _mockUnsupportedAsset;
    MockAllocator internal _mockAllocator;
    MockBridgeAdapter internal _mockBridgeAdapterAssets;
    MockBridgeAdapter internal _mockBridgeCcipFeeParams;
    MockDummyIouTokenManager internal _mockIouTokenManager;
    MockAssetRegistry internal _mockAssetRegistry;
    PriceOracle internal _priceOracle;
    MockTransferHelper internal _mockTransferHelper;
    WithdrawalExecutionPolicy internal _mockWithdrawalExecutionPolicy;
    PolicyRegistry internal _policyRegistry;

    EarningChainGateway internal _earningChainGateway;

    function _deployEarningChainGateway(
        MockAccessManager mockAccessManager,
        address iouTokenManager,
        address allocator,
        address priceOracle,
        address transferHelper,
        address policyRegistry
    ) internal returns (EarningChainGateway) {
        address earningChainGatewayImpl = address(
            new EarningChainGateway(
                ACCOUNTING_CHAIN_ID,
                allocator,
                priceOracle,
                iouTokenManager,
                transferHelper,
                policyRegistry,
                BURN_IOU_TOKEN_GAS_LIMIT
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
        earningChainGateway.addDataOnlyBridgeAdapter(ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams));
        vm.prank(admin);
        earningChainGateway.addFundsBridgeAdapter(
            address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        vm.prank(admin);
        earningChainGateway.addFundsBridgeAdapter(
            address(_mockGho), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        return earningChainGateway;
    }

    function _deployWithdrawalExecutionPolicy(address accessManager, address withdrawalExecutionPolicyApplier)
        internal
        returns (WithdrawalExecutionPolicy)
    {
        WithdrawalExecutionPolicy policy =
            new WithdrawalExecutionPolicy(accessManager, withdrawalExecutionPolicyApplier, 0, 1, 1);
        // forge-lint: disable-next-line(unsafe-typecast)
        policy.raiseRedemptionCapacity(uint128(MAX_REDEMPTION_CAPACITY));
        policy.raiseRedemptionRefillRate(1e30);
        return policy;
    }

    function setUp() public {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));

        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        _mockUnsupportedAsset =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Asset", "tUNSUPPORTED", 18)));

        _mockIouTokenManager = new MockDummyIouTokenManager();

        _mockAssetRegistry = new MockAssetRegistry();

        _mockAllocator = new MockAllocator();

        _mockAccessManager = new MockAccessManager(admin);

        _priceOracle = _deployPriceOracle(address(_mockAccessManager), 9_995e23);
        // Set mock prices (1 RAY = 1:1 price ratio)
        _mockAssetPrice(address(_priceOracle), address(_mockUsdt), MathLib.RAY);
        _mockAssetPrice(address(_priceOracle), address(_mockGho), MathLib.RAY);

        _mockTransferHelper = new MockTransferHelper();

        _mockBridgeAdapterAssets = new MockBridgeAdapter(address(_mockTransferHelper));

        _mockBridgeCcipFeeParams = new MockBridgeAdapter(address(_mockTransferHelper));

        _policyRegistry = new PolicyRegistry(address(_mockAccessManager));

        // Predict gateway proxy address after the (non-upgradeable) WithdrawalExecutionPolicy and gateway impl
        // deployments.
        uint256 deployerNonce = vm.getNonce(address(this));
        address expectedGatewayProxy = vm.computeCreateAddress(address(this), deployerNonce + 2);

        _mockWithdrawalExecutionPolicy =
            _deployWithdrawalExecutionPolicy(address(_mockAccessManager), expectedGatewayProxy);

        _earningChainGateway = _deployEarningChainGateway(
            _mockAccessManager,
            address(_mockIouTokenManager),
            address(_mockAllocator),
            address(_priceOracle),
            address(_mockTransferHelper),
            address(_policyRegistry)
        );
        _policyRegistry.setPolicy(
            keccak256(bytes("aave.stable-vault.EarningChainGateway.policy.withdrawal-execution")),
            address(_mockWithdrawalExecutionPolicy)
        );
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        new EarningChainGateway(
            ACCOUNTING_CHAIN_ID,
            address(_mockAllocator),
            address(_priceOracle),
            address(_mockIouTokenManager),
            address(0),
            address(_policyRegistry),
            BURN_IOU_TOKEN_GAS_LIMIT
        );
    }

    function test_constructor_reverts_ifPolicyRegistryIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new EarningChainGateway(
            ACCOUNTING_CHAIN_ID,
            address(_mockAllocator),
            address(_priceOracle),
            address(_mockIouTokenManager),
            address(_mockTransferHelper),
            address(0),
            BURN_IOU_TOKEN_GAS_LIMIT
        );
    }

    function test_constructor_reverts_ifAccountingChainIdIsZero() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        new EarningChainGateway(
            0,
            address(_mockAllocator),
            address(_priceOracle),
            address(_mockIouTokenManager),
            address(_mockTransferHelper),
            address(_policyRegistry),
            BURN_IOU_TOKEN_GAS_LIMIT
        );
    }

    function test_constructor_reverts_ifAccountingChainIdIsCurrentChainId() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        new EarningChainGateway(
            block.chainid,
            address(_mockAllocator),
            address(_priceOracle),
            address(_mockIouTokenManager),
            address(_mockTransferHelper),
            address(_policyRegistry),
            BURN_IOU_TOKEN_GAS_LIMIT
        );
    }

    function test_constructor_reverts_ifInvalidIouTokenManager() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new EarningChainGateway(
            ACCOUNTING_CHAIN_ID,
            address(_mockAllocator),
            address(_priceOracle),
            address(0),
            address(_mockTransferHelper),
            address(_policyRegistry),
            BURN_IOU_TOKEN_GAS_LIMIT
        );
    }

    function test_constructor_reverts_ifMinBurnIouTokenGasLimitIsZero() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        new EarningChainGateway(
            ACCOUNTING_CHAIN_ID,
            address(_mockAllocator),
            address(_priceOracle),
            address(_mockIouTokenManager),
            address(_mockTransferHelper),
            address(_policyRegistry),
            0
        );
    }

    function test_constructor_setsMinBurnIouTokenGasLimit_immutable() public view {
        assertEq(_earningChainGateway.MIN_BURN_IOU_TOKEN_PAYLOAD_EXECUTION_GAS_LIMIT(), BURN_IOU_TOKEN_GAS_LIMIT);
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

    function test_removeFundsBridgeAdapter_removesBridgeAdapter() public {
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.FundsBridgeAdapterRemoved(
            address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        vm.prank(admin);
        _earningChainGateway.removeFundsBridgeAdapter(
            address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
    }

    function test_initiateDataOnlyBridgeAdapterRemoval_reverts_ifLastDataOnlyBridgeAdapter() public {
        vm.expectRevert(IChainGateway.CannotRemoveLastDataOnlyBridgeAdapter.selector);
        vm.prank(admin);
        _earningChainGateway.initiateDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams)
        );
    }

    function test_finalizeDataOnlyBridgeAdapterRemoval_removesBridgeAdapter_ifRemovalWasInitiated() public {
        address bridgeAdapter = makeAddr("bridgeAdapter");

        vm.prank(admin);
        _earningChainGateway.addDataOnlyBridgeAdapter(ACCOUNTING_CHAIN_ID, bridgeAdapter);

        bytes32 removalId = keccak256(
            abi.encode(
                ACCOUNTING_CHAIN_ID,
                address(_mockBridgeCcipFeeParams),
                blockhash(block.number - 1),
                block.prevrandao,
                block.timestamp,
                address(_earningChainGateway)
            )
        );
        vm.expectEmit(true, true, true, true);
        emit IChainGateway.DataOnlyBridgeAdapterRemovalInitiated(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams), removalId
        );
        vm.prank(admin);
        bytes32 actualRemovalId = _earningChainGateway.initiateDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams)
        );
        assertEq(actualRemovalId, removalId);

        vm.expectEmit(true, true, true, true);
        emit IChainGateway.DataOnlyBridgeAdapterRemovalFinalized(ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams));
        vm.prank(admin);
        _earningChainGateway.finalizeDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams), removalId
        );

        assertEq(
            uint8(
                _earningChainGateway.getDataOnlyBridgeAdapterMode(
                    ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams)
                )
            ),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.NOT_SUPPORTED)
        );
        assertEq(
            uint8(_earningChainGateway.getDataOnlyBridgeAdapterMode(ACCOUNTING_CHAIN_ID, bridgeAdapter)),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE)
        );
    }

    function test_getDataOnlyBridgeAdapterRemovalId_tracksRemovalLifecycle() public {
        address bridgeAdapter = makeAddr("bridgeAdapter");

        assertEq(_earningChainGateway.getDataOnlyBridgeAdapterRemovalId(ACCOUNTING_CHAIN_ID, bridgeAdapter), bytes32(0));

        vm.prank(admin);
        _earningChainGateway.addDataOnlyBridgeAdapter(ACCOUNTING_CHAIN_ID, bridgeAdapter);
        assertEq(_earningChainGateway.getDataOnlyBridgeAdapterRemovalId(ACCOUNTING_CHAIN_ID, bridgeAdapter), bytes32(0));

        vm.prank(admin);
        bytes32 removalId = _earningChainGateway.initiateDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams)
        );
        assertEq(
            _earningChainGateway.getDataOnlyBridgeAdapterRemovalId(
                ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams)
            ),
            removalId
        );

        vm.prank(admin);
        _earningChainGateway.finalizeDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams), removalId
        );
        assertEq(
            _earningChainGateway.getDataOnlyBridgeAdapterRemovalId(
                ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams)
            ),
            bytes32(0)
        );
    }

    function test_finalizeDataOnlyBridgeAdapterRemoval_reverts_ifRemovalIdDoesNotMatch() public {
        address bridgeAdapter = makeAddr("bridgeAdapter");

        vm.prank(admin);
        _earningChainGateway.addDataOnlyBridgeAdapter(ACCOUNTING_CHAIN_ID, bridgeAdapter);

        vm.prank(admin);
        bytes32 removalId = _earningChainGateway.initiateDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams)
        );
        bytes32 invalidRemovalId = bytes32(uint256(removalId) ^ 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IChainGateway.InvalidDataOnlyBridgeAdapterRemovalId.selector, invalidRemovalId, removalId
            )
        );
        vm.prank(admin);
        _earningChainGateway.finalizeDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams), invalidRemovalId
        );
    }

    function test_finalizeDataOnlyBridgeAdapterRemoval_reverts_ifNotWhitelisted() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IChainGateway.UnexpectedDataOnlyBridgeAdapterMode.selector,
                uint8(IChainGateway.DataOnlyBridgeAdapterMode.NOT_SUPPORTED),
                uint8(IChainGateway.DataOnlyBridgeAdapterMode.RECEIVE_ONLY)
            )
        );
        vm.prank(admin);
        _earningChainGateway.finalizeDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, makeAddr("bridgeAdapter"), bytes32(0)
        );
    }

    function test_dataOnlyBridgeAdapterReceiveOnly_receivesButCannotSend() public {
        address replacementAdapter = makeAddr("replacementAdapter");
        address iouTokenRecipient = makeAddr("iouTokenRecipient");
        uint256 iouTokenAmountRay = 100_000;

        vm.prank(admin);
        _earningChainGateway.addDataOnlyBridgeAdapter(ACCOUNTING_CHAIN_ID, replacementAdapter);
        vm.prank(admin);
        _earningChainGateway.initiateDataOnlyBridgeAdapterRemoval(
            ACCOUNTING_CHAIN_ID, address(_mockBridgeCcipFeeParams)
        );

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            address(_mockBridgeCcipFeeParams),
            address(this),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0}))
        );

        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                )
            })
        );
        vm.expectCall(
            address(_mockIouTokenManager),
            abi.encodeCall(IIouTokenManager.mintTokens, (iouTokenRecipient, iouTokenAmountRay))
        );
        vm.prank(address(_mockBridgeCcipFeeParams));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, data);
    }

    function test_rescueTokens_transfersIdleFundsToMsgSender() public {
        address asset = address(_mockUsdt);
        uint256 amount = 1000000000000000000;
        assertEq(_mockUsdt.balanceOf(address(_earningChainGateway)), 0);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), 0);
        _mockUsdt.mint(address(_earningChainGateway), amount);
        assertEq(_mockUsdt.balanceOf(address(_earningChainGateway)), amount);
        vm.expectEmit(true, true, true, true);
        emit IRescuableToken.TokensRescued(asset, everyRoleAccount, amount);
        vm.prank(everyRoleAccount);
        _earningChainGateway.rescueTokens(asset, amount);
        assertEq(_mockUsdt.balanceOf(everyRoleAccount), amount);
        assertEq(_mockUsdt.balanceOf(address(_earningChainGateway)), 0);
    }

    function test_rescueNative_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, uint256 amount)
        public
    {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(_earningChainGateway));
        _mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(_earningChainGateway), IRescuableNative.rescueNative.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        _earningChainGateway.rescueNative(amount);
    }

    /// @dev `setUp` pre-wires (_mockUsdt, ACCOUNTING_CHAIN_ID, _mockBridgeAdapterAssets) and (_mockGho,
    /// ACCOUNTING_CHAIN_ID, _mockBridgeAdapterAssets). Fuzz inputs that hit either triple must be excluded.
    function _assumeFreshFundsBridgeAdapterTuple(address asset, uint256 chainId, address bridgeAdapter) internal view {
        vm.assume(asset != address(0) && bridgeAdapter != address(0) && chainId != 0 && chainId != block.chainid);
        vm.assume(asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE);
        vm.assume(
            !(asset == address(_mockUsdt) && chainId == ACCOUNTING_CHAIN_ID
                    && bridgeAdapter == address(_mockBridgeAdapterAssets))
        );
        vm.assume(
            !(asset == address(_mockGho) && chainId == ACCOUNTING_CHAIN_ID
                    && bridgeAdapter == address(_mockBridgeAdapterAssets))
        );
    }

    function test_isFundsBridgeAdapterSupported_returnsTrueAfterAdd(
        address asset,
        uint256 chainId,
        address bridgeAdapter
    ) public {
        _assumeFreshFundsBridgeAdapterTuple(asset, chainId, bridgeAdapter);

        assertFalse(_earningChainGateway.isFundsBridgeAdapterSupported(asset, chainId, bridgeAdapter));

        vm.prank(everyRoleAccount);
        _earningChainGateway.addFundsBridgeAdapter(asset, chainId, bridgeAdapter);

        assertTrue(_earningChainGateway.isFundsBridgeAdapterSupported(asset, chainId, bridgeAdapter));
    }

    function test_addFundsBridgeAdapter_setsExpectedBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter)
        public
    {
        _assumeFreshFundsBridgeAdapterTuple(asset, chainId, bridgeAdapter);
        vm.prank(admin);
        _earningChainGateway.addFundsBridgeAdapter(asset, chainId, bridgeAdapter);
        assertTrue(_earningChainGateway.isFundsBridgeAdapterSupported(asset, chainId, bridgeAdapter));
    }

    function test_addFundsBridgeAdapter_reverts_ifAlreadyAdded() public {
        address bridgeAdapter = makeAddr("bridgeAdapter");
        address asset = address(_mockUsdt);

        vm.prank(everyRoleAccount);
        _earningChainGateway.addFundsBridgeAdapter(asset, ACCOUNTING_CHAIN_ID, bridgeAdapter);
        vm.expectRevert(Errors.AddressAlreadyWhitelisted.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.addFundsBridgeAdapter(asset, ACCOUNTING_CHAIN_ID, bridgeAdapter);
    }

    function test_addFundsBridgeAdapter_reverts_ifAdapterIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.addFundsBridgeAdapter(address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(0));
    }

    function test_addFundsBridgeAdapter_reverts_ifChainIdIsZero() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.addFundsBridgeAdapter(address(_mockUsdt), 0, makeAddr("bridgeAdapter"));
    }

    function test_getAggregatedBalance_returnsExpectedBalance(uint256 amountUsdt, uint256 amountGho) public {
        amountUsdt = _boundAssetAmountAllowingZero(address(_mockUsdt), amountUsdt);
        amountGho = _boundAssetAmountAllowingZero(address(_mockGho), amountGho);

        IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(amountUsdt, amountGho);

        uint256 expectedTotalAssetsInRay =
            amountUsdt.assetDecimalsToRay(address(_mockUsdt)) + amountGho.assetDecimalsToRay(address(_mockGho));
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getTrustedAssetBalances.selector),
            abi.encode(allocatorBalances)
        );
        assertEq(_earningChainGateway.getAggregatedBalance(), expectedTotalAssetsInRay);
    }

    function test_exchangeIouTokens_exchangesIouTokensWithTokenBridgeFee(
        uint256 iouTokenAmountRay,
        address tokenOutReceiver,
        uint256 bridgeFeeAmount
    ) public {
        address bridgeFeePayer = tokenOutReceiver;
        // Two exchanges happen below, both consume from the redemption bucket.
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, (type(uint128).max - 1) / 2);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);
        vm.assume(tokenOutReceiver != address(0));
        _assumeNotProxyAdmin(tokenOutReceiver, address(_earningChainGateway));
        vm.assume(bridgeFeePayer != address(0));
        address bridgeFeeToken = address(_mockGho);

        address tokenOut = address(_mockUsdt);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);
        vm.assume(amountOut > 0);

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
                vm.mockCall(
                    address(_mockAllocator),
                    abi.encodeWithSelector(MockAllocator.getTrustedAssetBalances.selector),
                    abi.encode(allocatorBalances)
                );

                data = abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                        data: abi.encode(
                            IChainGateway.BurnIouTokenMessage({
                                iouTokenAmountBurnedRay: iouTokenAmountRay,
                                timestamp: block.timestamp,
                                blockNumber: block.number
                            })
                        )
                    })
                );
            }

            // Check the bridge adapter is called with expected parameters
            _mockGho.mint(bridgeFeePayer, bridgeFeeAmount);
            vm.prank(bridgeFeePayer);
            MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeCcipFeeParams), bridgeFeeAmount);

            bytes memory bridgeAdapterData =
                abi.encode(CcipAdapter.CcipFeeParams({feeToken: bridgeFeeToken, nativeFeeRefundThreshold: 0}));

            vm.expectCall(
                bridgeFeeToken,
                abi.encodeCall(
                    IERC20.transferFrom, (bridgeFeePayer, address(_mockBridgeCcipFeeParams), bridgeFeeAmount)
                )
            );
            vm.expectCall(
                address(_mockBridgeCcipFeeParams),
                abi.encodeCall(
                    IBridgeAdapter.publishDataOnlyMessage,
                    (ACCOUNTING_CHAIN_ID, data, bridgeFeePayer, DEFAULT_GAS_LIMIT, bridgeAdapterData)
                )
            );
            _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);
            vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));

            vm.prank(tokenOutReceiver);
            _earningChainGateway.exchangeIouTokens(
                iouTokenAmountRay,
                tokenOut,
                0,
                tokenOutReceiver,
                address(_mockBridgeCcipFeeParams),
                BURN_IOU_TOKEN_GAS_LIMIT,
                bridgeAdapterData,
                ""
            );
        }

        // Check that another exchange uses incremented nonce
        {
            _mockUsdt.mint(address(_mockAllocator), amountOut);

            bytes memory data;
            {
                bytes memory dataInner = abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: iouTokenAmountRay,
                        timestamp: block.timestamp,
                        blockNumber: block.number
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
            MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeCcipFeeParams), bridgeFeeAmount);

            bytes memory bridgeAdapterData =
                abi.encode(CcipAdapter.CcipFeeParams({feeToken: bridgeFeeToken, nativeFeeRefundThreshold: 0}));

            vm.expectCall(
                bridgeFeeToken,
                abi.encodeCall(
                    IERC20.transferFrom, (bridgeFeePayer, address(_mockBridgeCcipFeeParams), bridgeFeeAmount)
                )
            );
            vm.expectCall(
                address(_mockBridgeCcipFeeParams),
                abi.encodeCall(
                    IBridgeAdapter.publishDataOnlyMessage,
                    (ACCOUNTING_CHAIN_ID, data, bridgeFeePayer, DEFAULT_GAS_LIMIT, bridgeAdapterData)
                )
            );
            _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);
            vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));
            vm.prank(tokenOutReceiver);
            _earningChainGateway.exchangeIouTokens(
                iouTokenAmountRay,
                tokenOut,
                0,
                tokenOutReceiver,
                address(_mockBridgeCcipFeeParams),
                BURN_IOU_TOKEN_GAS_LIMIT,
                bridgeAdapterData,
                ""
            );
        }
    }

    function test_exchangeIouTokens_exchangesIouTokensWithNativeBridgeFee(
        uint256 iouTokenAmountRay,
        address tokenOutReceiver,
        uint256 bridgeFeeAmount
    ) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);
        vm.assume(tokenOutReceiver != address(0));
        _assumeNotProxyAdmin(tokenOutReceiver, address(_earningChainGateway));

        address tokenOut = address(_mockUsdt);
        vm.assume(iouTokenAmountRay.rayToAssetDecimals(tokenOut) > 0);

        bytes memory bridgeAdapterData;
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
                abi.encodeWithSelector(MockAllocator.getTrustedAssetBalances.selector),
                abi.encode(allocatorBalances)
            );

            bridgeAdapterData = abi.encode(
                CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})
            );

            uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);
            _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);
            vm.expectCall(address(_mockUsdt), abi.encodeCall(IERC20.transfer, (tokenOutReceiver, amountOut)));
            vm.expectCall(
                address(_mockBridgeCcipFeeParams),
                _expectedBurnIouCalldata(iouTokenAmountRay, tokenOutReceiver, DEFAULT_GAS_LIMIT, bridgeAdapterData)
            );
        }

        vm.deal(tokenOutReceiver, bridgeFeeAmount);
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens{value: bridgeFeeAmount}(
            iouTokenAmountRay,
            tokenOut,
            0,
            tokenOutReceiver,
            address(_mockBridgeCcipFeeParams),
            BURN_IOU_TOKEN_GAS_LIMIT,
            bridgeAdapterData,
            ""
        );
    }

    function test_exchangeIouTokens_rollsBackBurnAndAssetTransferIfBurnMessagePublishReverts(uint256 iouTokenAmountRay)
        public
    {
        iouTokenAmountRay = _boundRayAmount(iouTokenAmountRay);
        vm.assume(iouTokenAmountRay < MAX_REDEMPTION_CAPACITY);
        address tokenOutReceiver = makeAddr("tokenOutReceiver");
        address tokenOut = address(_mockUsdt);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);
        vm.assume(amountOut > 0);

        _mockUsdt.mint(address(_mockAllocator), amountOut);
        _mockTransferHelper.mockAsset(tokenOut, amountOut);
        IAllocator.AllocatorBalance[] memory allocatorBalances = _buildAllocatorBalances(123e18, 456e18);
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getTrustedAssetBalances.selector),
            abi.encode(allocatorBalances)
        );

        bytes memory bridgeAdapterData =
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0}));
        _mockBridgeCcipFeeParams.setShouldRevertPublish(true);

        vm.expectRevert(MockBridgeAdapter.PublishMessageFailed.selector);
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            tokenOut,
            0,
            tokenOutReceiver,
            address(_mockBridgeCcipFeeParams),
            BURN_IOU_TOKEN_GAS_LIMIT,
            bridgeAdapterData,
            ""
        );

        assertEq(_mockIouTokenManager.burnedAmount(tokenOutReceiver), 0, "IOU burn did not roll back");
        assertEq(_mockIouTokenManager.totalBurned(), 0, "total IOU burn did not roll back");
        assertEq(_mockUsdt.balanceOf(tokenOutReceiver), 0, "asset transfer should not happen");
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), amountOut, "TransferHelper balance changed");
    }

    function test_exchangeIouTokens_emitsAssetOutflow(uint256 iouTokenAmountRay) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        address tokenOut = address(_mockUsdt);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);
        vm.assume(amountOut > 0);

        address user = makeAddr("user");
        _assumeNotProxyAdmin(user, address(_earningChainGateway));

        _mockUsdt.mint(address(_mockAllocator), amountOut);
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);

        vm.expectEmit(true, true, true, true);
        emit IEarningChainGateway.AssetOutflow(tokenOut, amountOut);

        vm.prank(user);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            tokenOut,
            0,
            user,
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    /// @dev Defense-in-depth: the policy is expected to deduct a fee, so the post-fee amount must be
    /// `<= iouTokenAmountRay`. A misconfigured or compromised policy returning more would otherwise inflate the
    /// withdrawal.
    function test_exchangeIouTokens_reverts_ifPolicyReturnsMoreThanIouAmount(
        uint256 iouTokenAmountRay,
        uint256 policyReturnedAmountRay
    ) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        vm.assume(iouTokenAmountRay < type(uint256).max);
        policyReturnedAmountRay = bound(policyReturnedAmountRay, iouTokenAmountRay + 1, type(uint256).max);

        address user = makeAddr("user");
        _assumeNotProxyAdmin(user, address(_earningChainGateway));

        vm.mockCall(
            address(_mockWithdrawalExecutionPolicy),
            abi.encodeWithSelector(IWithdrawalExecutionPolicy.applyWithdrawalExecutionPolicy.selector),
            abi.encode(policyReturnedAmountRay)
        );

        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            address(_mockUsdt),
            0,
            user,
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    /// @dev When the withdrawal-execution policy is unregistered, the gateway skips the policy call and treats the IOU
    /// amount as the post-fee amount, so the user receives the full `iouTokenAmountRay` truncated to asset decimals.
    function test_exchangeIouTokens_withdrawsFullIouAmountIfNoPolicyRegistered(uint256 iouTokenAmountRay) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        address tokenOut = address(_mockUsdt);
        uint256 expectedAmountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);
        vm.assume(expectedAmountOut > 0);

        address user = makeAddr("user");
        _assumeNotProxyAdmin(user, address(_earningChainGateway));

        _mockUsdt.mint(address(_mockAllocator), expectedAmountOut);
        _mockTransferHelper.mockAsset(tokenOut, expectedAmountOut);

        _policyRegistry.setPolicy(
            keccak256(bytes("aave.stable-vault.EarningChainGateway.policy.withdrawal-execution")), address(0)
        );

        vm.expectCall(
            address(_mockWithdrawalExecutionPolicy),
            abi.encodeWithSelector(IWithdrawalExecutionPolicy.applyWithdrawalExecutionPolicy.selector),
            0
        );

        vm.prank(user);
        uint256 amountOut = _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            tokenOut,
            0,
            user,
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );

        assertEq(amountOut, expectedAmountOut);
        assertEq(_mockUsdt.balanceOf(user), expectedAmountOut);
    }

    function test_exchangeIouTokens_reverts_ifZeroAmountAsIouTokenAmountRay() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        _earningChainGateway.exchangeIouTokens(
            0,
            address(_mockUsdt),
            0,
            makeAddr("tokenOutReceiver"),
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifBurnIouTokenGasLimitBelowMinimum(uint256 iouTokenAmountRay) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);

        vm.expectRevert(Errors.InvalidGasLimit.selector);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            address(_mockUsdt),
            0,
            makeAddr("tokenOutReceiver"),
            address(_mockBridgeCcipFeeParams),
            BURN_IOU_TOKEN_GAS_LIMIT - 1,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifZeroAssetOutAmount_fromRayConversion() public {
        // Converting this to 6 decimals will result in 0
        uint256 iouTokenAmountRay = 1e20;

        // Put funds idle into TH to mimic withdrawal from Allocator
        //_mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);

        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            address(_mockUsdt),
            0,
            makeAddr("tokenOutReceiver"),
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifZeroAssetOutAmount_fromWithdrawalFee() public {
        // Converting this to 6 decimals will result in 1 unit withdrawal, but withdrawal fee is 1e21 so amount out is 0
        uint256 iouTokenAmountRay = 1e21;

        vm.mockCall(
            address(_mockWithdrawalExecutionPolicy),
            abi.encodeWithSelector(IWithdrawalExecutionPolicy.applyWithdrawalExecutionPolicy.selector),
            abi.encode(uint256(0)) // amountOutRay = 0, simulating 100% fee
        );

        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            address(_mockUsdt),
            0,
            makeAddr("tokenOutReceiver"),
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifInsufficientValueForNativeBridgeFee(uint256 iouTokenAmountRay) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(address(_mockUsdt));
        vm.assume(amountOut > 0);
        // Put funds idle into TH to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);
        _mockBridgeCcipFeeParams.mockFeeAmount(1);

        vm.expectRevert(Errors.InsufficientFunds.selector);
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            address(_mockUsdt),
            0,
            makeAddr("tokenOutReceiver"),
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifAssetWithdrawalNotAllowed(uint256 iouTokenAmountRay) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(address(_mockUnsupportedAsset));
        vm.assume(amountOut > 0);
        // Put funds idle into TH to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUnsupportedAsset), amountOut);

        vm.mockCall(
            address(_mockWithdrawalExecutionPolicy),
            abi.encodeWithSelector(
                IWithdrawalExecutionPolicy.applyWithdrawalExecutionPolicy.selector,
                address(_mockUnsupportedAsset),
                iouTokenAmountRay
            ),
            abi.encode(iouTokenAmountRay)
        );

        // Mock a revert from Allocator since the strategy is not a registered asset.
        vm.mockCallRevert(
            address(_mockAllocator),
            abi.encodeWithSelector(
                IAllocator.withdraw.selector,
                address(_mockUnsupportedAsset),
                iouTokenAmountRay.rayToAssetDecimals(address(_mockUnsupportedAsset))
            ),
            abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset))
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(_mockUnsupportedAsset)));
        _earningChainGateway.exchangeIouTokens(
            iouTokenAmountRay,
            address(_mockUnsupportedAsset),
            0,
            makeAddr("tokenOutReceiver"),
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifNotWhitelistedBridgeAdapter() public {
        uint256 iouTokenAmountRay = 100_000 * 10 ** 27;
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(address(_mockUsdt));
        address unsupportedAdapter = makeAddr("unsupportedAdapter");
        // Put funds idle into TH to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);

        address tokenOutReceiver = makeAddr("tokenOutReceiver");
        uint256 bridgeFeeAmount = 123;
        vm.deal(tokenOutReceiver, bridgeFeeAmount);
        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens{value: bridgeFeeAmount}(
            iouTokenAmountRay,
            address(_mockUsdt),
            0,
            tokenOutReceiver,
            unsupportedAdapter,
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifAdapterNeverWhitelisted() public {
        address bogusAdapter = makeAddr("bogusAdapter");
        uint256 bridgeFeeAmount = 123;
        address tokenOutReceiver = makeAddr("tokenOutReceiver");
        vm.deal(tokenOutReceiver, bridgeFeeAmount);
        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens{value: bridgeFeeAmount}(
            100e27,
            address(_mockUsdt),
            0,
            tokenOutReceiver,
            bogusAdapter,
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_exchangeIouTokens_reverts_ifAmountOutIsLessThanMinAmountOut(
        uint256 iouTokenAmountRay,
        uint256 minAmountOut
    ) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(address(_mockUsdt));
        minAmountOut = bound(minAmountOut, amountOut + 1, type(uint256).max);
        // Put funds idle into TH to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountOut);

        address tokenOutReceiver = makeAddr("tokenOutReceiver");
        uint256 bridgeFeeAmount = 123;
        vm.deal(tokenOutReceiver, bridgeFeeAmount);
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        vm.prank(tokenOutReceiver);
        _earningChainGateway.exchangeIouTokens{value: bridgeFeeAmount}(
            iouTokenAmountRay,
            address(_mockUsdt),
            minAmountOut,
            tokenOutReceiver,
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_pushFundsToAccountingChain_bridgesAssetWithTokenBridgeFee(
        uint256 amountTokenUnits,
        uint256 bridgeFeeAmount
    ) public {
        uint256 amountToken = _boundAssetAmount(address(_mockUsdt), amountTokenUnits);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(address(_mockGho), bridgeFeeAmount);

        // Mock tokens into TransferHelper to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

        address sender = makeAddr("randomAccount");

        _mockGho.mint(sender, bridgeFeeAmount);
        vm.prank(sender);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeAdapterAssets), bridgeFeeAmount);

        bytes memory returnFundsMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.RETURN_FUNDS,
                data: abi.encode(
                    IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                )
            })
        );

        bytes memory bridgeAdapterData =
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: bridgeFeeToken, nativeFeeRefundThreshold: 0}));

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            0,
            abi.encodeCall(
                IBridgeAdapter.publishMessageWithFunds,
                (
                    ACCOUNTING_CHAIN_ID,
                    address(_mockUsdt),
                    amountToken,
                    returnFundsMessageEncoded,
                    sender,
                    DEFAULT_GAS_LIMIT,
                    bridgeAdapterData
                )
            )
        );
        vm.expectCall(address(_mockAllocator), abi.encodeCall(IAllocator.withdraw, (address(_mockUsdt), amountToken)));

        vm.prank(sender);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt), amountToken, address(_mockBridgeAdapterAssets), DEFAULT_GAS_LIMIT, bridgeAdapterData, ""
        );
    }

    function test_pushFundsToAccountingChain_queriesRegistryWithBridgePolicyId(
        uint256 amountTokenUnits,
        uint256 bridgeFeeAmount
    ) public {
        uint256 amountToken = _boundAssetAmount(address(_mockUsdt), amountTokenUnits);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(address(_mockGho), bridgeFeeAmount);

        _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

        address sender = makeAddr("randomAccount");
        _mockGho.mint(sender, bridgeFeeAmount);
        vm.prank(sender);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeAdapterAssets), bridgeFeeAmount);

        bytes memory bridgeAdapterData =
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: bridgeFeeToken, nativeFeeRefundThreshold: 0}));

        vm.expectCall(
            address(_policyRegistry),
            abi.encodeCall(IPolicyRegistry.getPolicy, keccak256("aave.stable-vault.EarningChainGateway.policy.bridge"))
        );

        vm.prank(sender);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt), amountToken, address(_mockBridgeAdapterAssets), DEFAULT_GAS_LIMIT, bridgeAdapterData, ""
        );
    }

    function test_pushFundsToAccountingChain_bridgesAssetWithFeeTokenSameAsAsset(
        uint256 amountTokenUnits,
        uint256 bridgeFeeAmount
    ) public {
        uint256 amountToken = _boundAssetAmount(address(_mockGho), amountTokenUnits);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(address(_mockGho), bridgeFeeAmount);

        // Mock tokens into TransferHelper to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockGho), amountToken);

        address sender = makeAddr("randomAccount");

        _mockGho.mint(sender, bridgeFeeAmount);
        vm.prank(sender);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeAdapterAssets), bridgeFeeAmount);

        bytes memory returnFundsMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.RETURN_FUNDS,
                data: abi.encode(
                    IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                )
            })
        );

        bytes memory bridgeAdapterData =
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: bridgeFeeToken, nativeFeeRefundThreshold: 0}));

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            abi.encodeCall(
                IBridgeAdapter.publishMessageWithFunds,
                (
                    ACCOUNTING_CHAIN_ID,
                    address(_mockGho),
                    amountToken,
                    returnFundsMessageEncoded,
                    sender,
                    DEFAULT_GAS_LIMIT,
                    bridgeAdapterData
                )
            )
        );
        vm.expectCall(address(_mockAllocator), abi.encodeCall(IAllocator.withdraw, (address(_mockGho), amountToken)));

        // Call from random account to ensure the fee payer is used
        vm.prank(sender);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockGho), amountToken, address(_mockBridgeAdapterAssets), DEFAULT_GAS_LIMIT, bridgeAdapterData, ""
        );
    }

    function test_pushFundsToAccountingChain_bridgesAssetWithNativeBridgeFee(
        uint256 amountTokenUnits,
        uint256 bridgeFeeAmount
    ) public {
        uint256 amountToken = _boundAssetAmount(address(_mockUsdt), amountTokenUnits);
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);

        // Mock tokens into TransferHelper to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

        address bridgeFeeToken = Constants.NATIVE_CURRENCY;
        address feePayer = makeAddr("feePayer");

        vm.deal(feePayer, bridgeFeeAmount);

        bytes memory returnFundsMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.RETURN_FUNDS,
                data: abi.encode(
                    IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                )
            })
        );

        bytes memory bridgeAdapterData =
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: bridgeFeeToken, nativeFeeRefundThreshold: 0}));

        vm.expectCall(
            address(_mockBridgeAdapterAssets),
            bridgeFeeAmount,
            abi.encodeCall(
                IBridgeAdapter.publishMessageWithFunds,
                (
                    ACCOUNTING_CHAIN_ID,
                    address(_mockUsdt),
                    amountToken,
                    returnFundsMessageEncoded,
                    feePayer,
                    DEFAULT_GAS_LIMIT,
                    bridgeAdapterData
                )
            )
        );

        vm.prank(feePayer);
        _earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
            address(_mockUsdt), amountToken, address(_mockBridgeAdapterAssets), DEFAULT_GAS_LIMIT, bridgeAdapterData, ""
        );
    }

    function test_pushFundsToAccountingChain_emitsAssetOutflow(uint256 amountToken) public {
        amountToken = _boundAssetAmount(address(_mockUsdt), amountToken);
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

        address sender = makeAddr("randomAccount");

        vm.expectEmit(true, true, true, true);
        emit IEarningChainGateway.AssetOutflow(address(_mockUsdt), amountToken);

        vm.prank(sender);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            amountToken,
            address(_mockBridgeAdapterAssets),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_pushFundsToAccountingChain_withArbitraryData_emitsFundsSent() public {
        uint256 amountToken = 1000000000000000000;
        amountToken = _boundAssetAmount(address(_mockUsdt), amountToken);
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

        vm.expectEmit(true, true, true, true);
        emit IChainGateway.FundsSent(address(_mockUsdt), amountToken, ACCOUNTING_CHAIN_ID);

        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            amountToken,
            address(_mockBridgeAdapterAssets),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_pushFundsToAccountingChain_withoutArbitraryData_emitsFundsSent() public {
        uint256 amountToken = 1000000000000000000;
        amountToken = _boundAssetAmount(address(_mockUsdt), amountToken);
        _mockTransferHelper.mockAsset(address(_mockUsdt), amountToken);

        vm.expectEmit(true, true, true, true);
        emit IChainGateway.FundsSent(address(_mockUsdt), amountToken, ACCOUNTING_CHAIN_ID);

        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            amountToken,
            address(_mockBridgeAdapterAssets),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
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
            address(_mockBridgeAdapterAssets),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_pushFundsToAccountingChain_reverts_ifZeroAmountAsAmount() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            0,
            address(_mockBridgeAdapterAssets),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_pushFundsToAccountingChain_reverts_ifInsufficientValueForNativeBridgeFee(uint256 amount) public {
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        // Put funds idle in Allocator to allow withdrawal to EarningChainGateway
        _mockUsdt.mint(address(_mockAllocator), amount);
        _mockBridgeAdapterAssets.mockFeeAmount(1);

        vm.expectRevert(Errors.InsufficientFunds.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            amount,
            address(_mockBridgeAdapterAssets),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_pushFundsToAccountingChain_reverts_ifAdapterNotFound(uint256 amount, uint256 bridgeFeeAmount) public {
        address bridgeFeePayer = everyRoleAccount;
        amount = _boundAssetAmount(address(_mockUsdt), amount);
        address bridgeFeeToken = address(_mockGho);
        bridgeFeeAmount = _boundAssetAmount(address(_mockGho), bridgeFeeAmount);

        // Remove the bridge adapter for the asset being bridged
        vm.prank(admin);
        _earningChainGateway.removeFundsBridgeAdapter(
            address(_mockUsdt), ACCOUNTING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );

        // Mock tokens into TransferHelper to mimic withdrawal from Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), amount);

        // transfer funds to fee payer
        _mockGho.mint(bridgeFeePayer, bridgeFeeAmount);
        vm.prank(bridgeFeePayer);
        MockNonStandardErc20(bridgeFeeToken).approve(address(_mockBridgeAdapterAssets), bridgeFeeAmount);

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            amount,
            address(_mockBridgeAdapterAssets),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: bridgeFeeToken, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_pushFundsToAccountingChain_reverts_ifAdapterNeverWhitelisted() public {
        address bogusAdapter = makeAddr("bogusAdapter");
        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            address(_mockUsdt),
            100,
            bogusAdapter,
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    function test_pushFundsToAccountingChain_reverts_ifAssetIsDataOnlyBridgeAndAmountIsNonZero() public {
        // The data-only sentinel is not a real ERC20; mock balanceOf so the
        // assertingTransferHelperBalanceFor modifier can read a balance for it
        // and we can reach the InvalidParameter check inside _sendCrossChainMessage.
        vm.mockCall(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            abi.encodeWithSelector(IERC20.balanceOf.selector),
            abi.encode(uint256(0))
        );

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(everyRoleAccount);
        _earningChainGateway.pushFundsToAccountingChain(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            100,
            address(_mockBridgeCcipFeeParams),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
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
            address(_mockBridgeAdapterAssets),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})),
            ""
        );
    }

    /// @dev Under the opaque-bytes dispatch shape the `feePayer == msg.sender` guard was dropped
    /// (ERC20 approval semantics already prevent forgery). Removed the prior `InvalidBridgeFeePayer`
    /// revert test — the equivalent guarantee is now exercised by the token-fee path (a forged
    /// feePayer without approval reverts via ERC20) covered below in the other push-funds tests.

    function test_sendBridgeIouTokenMessageWithFeePayer_withTokenBridgeFee(
        address bridgeFeePayer,
        uint256 feeAmount,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        feeAmount = _boundNativeAmount(feeAmount);
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        vm.assume(bridgeFeePayer != address(0));

        // Use GHO as the bridge fee token
        address feeToken = address(_mockGho);
        // Under the opaque-bytes shape, fee-staging is owned by the adapter: mint to feePayer and
        // approve the adapter (MockBridgeAdapter mirrors the real CcipAdapter safeTransferFrom flow).
        IMockErc20(feeToken).mint(bridgeFeePayer, feeAmount);
        vm.prank(bridgeFeePayer);
        MockNonStandardErc20(feeToken).approve(address(_mockBridgeCcipFeeParams), feeAmount);

        // Expect call to Bridge Adapter to publish message with fee payer
        vm.expectCall(
            address(_mockBridgeCcipFeeParams),
            abi.encodeCall(
                IBridgeAdapter.publishDataOnlyMessage,
                (
                    ACCOUNTING_CHAIN_ID,
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
                    abi.encode(CcipAdapter.CcipFeeParams({feeToken: feeToken, nativeFeeRefundThreshold: 0}))
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            address(_mockBridgeCcipFeeParams),
            bridgeFeePayer,
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: address(_mockGho), nativeFeeRefundThreshold: 0}))
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_withNativeBridgeFee(
        address bridgeFeePayer,
        uint256 bridgeFeeAmount,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        bridgeFeeAmount = _boundNativeAmount(bridgeFeeAmount);
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
        vm.assume(bridgeFeePayer != address(0));
        // Under the opaque-bytes shape, native fee is supplied via msg.value to the gateway (not
        // pre-funded into TransferHelper). The adapter forwards it through on the wire.
        vm.deal(address(_mockIouTokenManager), bridgeFeeAmount);

        vm.expectCall(
            address(_mockBridgeCcipFeeParams),
            bridgeFeeAmount,
            abi.encodeCall(
                IBridgeAdapter.publishDataOnlyMessage,
                (
                    ACCOUNTING_CHAIN_ID,
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
                    abi.encode(
                        CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})
                    )
                )
            )
        );

        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer{value: bridgeFeeAmount}(
            ACCOUNTING_CHAIN_ID,
            iouTokenRecipient,
            iouTokenAmountRay,
            address(_mockBridgeCcipFeeParams),
            bridgeFeePayer,
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0}))
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifInvalidMessageSender() public {
        // Context: only callable by IOU Token Manager
        vm.expectRevert(IChainGateway.OnlyIouTokenManager.selector);
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            EARNING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000,
            address(_mockBridgeCcipFeeParams),
            address(this),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: address(_mockUsdt), nativeFeeRefundThreshold: 0}))
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifAdapterNotFound() public {
        address unsupportedAdapter = makeAddr("unsupportedAdapter");

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            100_000,
            unsupportedAdapter,
            address(this),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: address(_mockUsdt), nativeFeeRefundThreshold: 0}))
        );
    }

    function test_sendBridgeIouTokenMessageWithFeePayer_reverts_ifIouTokenAmountIsZero() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(address(_mockIouTokenManager));
        _earningChainGateway.sendBridgeIouTokenMessageWithFeePayer(
            ACCOUNTING_CHAIN_ID,
            makeAddr("iouTokenRecipient"),
            0,
            makeAddr("bridgeAdapter"),
            address(this),
            DEFAULT_GAS_LIMIT,
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: address(_mockUsdt), nativeFeeRefundThreshold: 0}))
        );
    }

    function test_receiveMessage_whenBridgeIouTokenMessageIsReceived(
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);
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
        vm.prank(address(_mockBridgeCcipFeeParams));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, data);
    }

    function test_receiveMessage_givenWhitelistedNonDefaultBridgeAdapter(
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        // Context: this should be the case for any valid message type

        iouTokenAmountRay = bound(_boundRayAmount(iouTokenAmountRay), 1, type(uint128).max - 1);

        // Add a new whitelisted bridge adapter for message bridge
        address unknownAdapter = makeAddr("unknownAdapter");
        vm.prank(admin);
        _earningChainGateway.addDataOnlyBridgeAdapter(ACCOUNTING_CHAIN_ID, unknownAdapter);

        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                )
            })
        );
        vm.prank(address(unknownAdapter));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, data);
    }

    function test_receiveMessage_whenBridgeFundsIsReceived(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        // mint this contract with the assets to mimic the Bridge Adapter
        _mockUsdt.mint(address(_mockBridgeAdapterAssets), amountUsdt);
        vm.prank(address(_mockBridgeAdapterAssets));
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_earningChainGateway), amountUsdt);

        vm.expectCall(address(_mockAllocator), abi.encodeCall(IAllocator.deposit, (address(_mockUsdt), amountUsdt)));

        vm.prank(address(_mockBridgeAdapterAssets));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, address(_mockUsdt), amountUsdt, "");
    }

    function test_receiveMessage_reverts_whenBridgeIouTokenIsBundledWithFunds(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.DataNotAllowedWithFunds.selector);
        vm.prank(address(_mockBridgeAdapterAssets));
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
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

    function test_receiveMessage_whenBridgeFundsIsReceived_emitsEvent() public {
        uint256 amountUsdt = 1000000000000000000;
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectEmit(true, true, true, true);
        emit IChainGateway.FundsReceived(address(_mockUsdt), amountUsdt, ACCOUNTING_CHAIN_ID);

        vm.prank(address(_mockBridgeAdapterAssets));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, address(_mockUsdt), amountUsdt, "");
    }

    function test_receiveMessage_receiveFunds_succeedsWhenUnknownAdapter(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);
        address bridgeAdapter = makeAddr("bridgeAdapter");
        MockNonStandardErc20(address(_mockUsdt)).mint(address(bridgeAdapter), amountUsdt);

        // Mimic usdt is transferred to the TransferHelper from the bridge adapter
        _mockUsdt.mint(address(_mockTransferHelper), amountUsdt);

        vm.prank(bridgeAdapter);
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, address(_mockUsdt), amountUsdt, "");

        // Check balance of TransferHelper is amountUsdt as it would not have been pulled down by mock Allocator
        // Funds are transferred to the TransferHelper from the bridge adapter
        assertEq(IERC20(address(_mockUsdt)).balanceOf(address(_mockTransferHelper)), amountUsdt);
    }

    function test_receiveMessage_noops_whenNoFundsAndNoData() public {
        vm.mockCallRevert(
            address(_mockAllocator), abi.encodeWithSelector(IAllocator.deposit.selector), bytes("unexpected")
        );

        vm.prank(makeAddr("notAdapter"));
        _earningChainGateway.receiveMessage(ACCOUNTING_CHAIN_ID, address(0), 0, "");
    }

    function test_receiveMessage_reverts_whenReturnFundsIsBundledWithFunds(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.DataNotAllowedWithFunds.selector);
        vm.prank(address(_mockBridgeAdapterAssets));
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
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
        vm.prank(address(_mockBridgeCcipFeeParams));
        vm.expectRevert(IChainGateway.InvalidMessageType.selector);
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.INVALID, data: abi.encode(keccak256(hex"c0ffee"))
                })
            )
        );
    }

    function test_receiveMessage_reverts_whenInvalidMessageTypeIsBundledWithFunds(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.DataNotAllowedWithFunds.selector);
        vm.prank(address(_mockBridgeAdapterAssets));
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
            address(_mockUsdt),
            amountUsdt,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.INVALID, data: abi.encode(keccak256(hex"c0ffee"))
                })
            )
        );
    }

    function test_reverts_receiveMessage_ifNotAdapter() public {
        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(makeAddr("notAdapter"));
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
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

    function test_receiveMessage_reverts_whenFundsAndDataComeFromDataOnlyAdapter(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_mockBridgeCcipFeeParams));
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
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

    function test_receiveMessage_reverts_whenFundsAndDataComeFromUnsupportedAssetAdapter(uint256 amountUsdt) public {
        amountUsdt = _boundAssetAmount(address(_mockUsdt), amountUsdt);

        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(makeAddr("unsupportedAdapter"));
        _earningChainGateway.receiveMessage(
            ACCOUNTING_CHAIN_ID,
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

    function test_exchangeIouTokens_reentrancyNotAllowedOnExchangeIouTokens() public {
        address attacker = makeAddr("attacker");

        MockReentrantErc20 reentrantAsset = new MockReentrantErc20("Reentrant Token", "REENT", 18);

        // Add bridge adapter for the reentrant asset
        MockBridgeAdapter reentrantBridgeAdapter = new MockBridgeAdapter(address(_mockTransferHelper));
        vm.prank(admin);
        _earningChainGateway.addFundsBridgeAdapter(
            address(reentrantAsset), ACCOUNTING_CHAIN_ID, address(reentrantBridgeAdapter)
        );

        uint256 iouTokenAmountRay = 1000e27; // 1000 IOU tokens in RAY
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(address(reentrantAsset));

        // Mock the allocator balance to return the reentrant asset
        IAllocator.AllocatorBalance[] memory allocatorBalances = new IAllocator.AllocatorBalance[](1);
        allocatorBalances[0] = IAllocator.AllocatorBalance({asset: address(reentrantAsset), amount: amountOut});
        vm.mockCall(
            address(_mockAllocator),
            abi.encodeWithSelector(MockAllocator.getTrustedAssetBalances.selector),
            abi.encode(allocatorBalances)
        );

        // Mock the transfer helper to have the reentrant asset
        _mockTransferHelper.mockAsset(address(reentrantAsset), amountOut);

        // Mint reentrant tokens to the transfer helper (simulating allocator withdrawal)
        reentrantAsset.mint(address(_mockTransferHelper), amountOut);

        // Setup the reentrant callback: when transfer() is called, re-enter exchangeIouTokens
        uint256 bridgeFeeAmount = 100;
        vm.deal(attacker, bridgeFeeAmount * 2);

        bytes memory reentrantCcipFeeParams =
            abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0}));
        reentrantAsset.setReentrantCall(
            address(_earningChainGateway),
            abi.encodeCall(
                IEarningChainGateway.exchangeIouTokens,
                (
                    iouTokenAmountRay,
                    address(reentrantAsset),
                    0,
                    attacker,
                    address(_mockBridgeCcipFeeParams),
                    BURN_IOU_TOKEN_GAS_LIMIT,
                    reentrantCcipFeeParams,
                    ""
                )
            )
        );

        // Execute exchangeIouTokens - should revert with ReentrancyGuardReentrantCall when trying to re-enter
        vm.prank(attacker);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        _earningChainGateway.exchangeIouTokens{value: bridgeFeeAmount}(
            iouTokenAmountRay,
            address(reentrantAsset),
            0,
            attacker,
            address(_mockBridgeCcipFeeParams),
            BURN_IOU_TOKEN_GAS_LIMIT,
            reentrantCcipFeeParams,
            ""
        );
    }

    ////////////////////////////// HELPERS ///////////////////////////////

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

    /// @dev Composes the canonical BURN_IOU_TOKEN cross-chain payload + the adapter publish-call selector.
    /// Lives behind a helper so the deeply-nested struct construction doesn't compete for stack frame
    /// slots with the test body's locals (Solidity stack-too-deep avoidance under explicit feePayer
    /// propagation).
    function _expectedBurnIouCalldata(
        uint256 iouTokenAmountRay,
        address feePayer,
        uint256 gasLimit,
        bytes memory bridgeAdapterData
    ) internal view returns (bytes memory) {
        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: iouTokenAmountRay,
                        timestamp: block.timestamp,
                        blockNumber: block.number
                    })
                )
            })
        );
        return abi.encodeCall(
            IBridgeAdapter.publishDataOnlyMessage, (ACCOUNTING_CHAIN_ID, data, feePayer, gasLimit, bridgeAdapterData)
        );
    }
}
