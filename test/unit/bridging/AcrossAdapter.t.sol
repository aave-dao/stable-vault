// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {AcrossAdapter} from "src/bridging/across/AcrossAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";

import {IAcrossSpokePoolV3} from "src/bridging/across/IAcrossSpokePoolV3.sol";
import {IAcrossV3Receiver} from "src/bridging/across/IAcrossV3Receiver.sol";
import {IAcrossBridgeAdapter} from "src/interfaces/IAcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {Errors} from "src/types/Errors.sol";
import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAccountingChainGateway} from "test/mocks/MockAccountingChainGateway.sol";
import {MockAcrossSpokePool} from "test/mocks/MockAcrossSpokePool.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";
import {MockEarningChainGateway} from "test/mocks/MockEarningChainGateway.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract AcrossAdapterTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMockErc20;

    struct DepositV3ExpectCallParams {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
        bytes32 messageId;
    }

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;
    uint256 internal DEFAULT_GAS_LIMIT = 100000;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    MockAccessManager internal _mockAccessManager;
    MockAssetRegistry internal _mockAssetRegistry;
    IMockErc20 internal _mockUsdtAccountingChain;
    IMockErc20 internal _mockGhoAccountingChain;
    IMockErc20 internal _mockUsdtEarningChain;
    IMockErc20 internal _mockGhoEarningChain;
    MockTransferHelper internal _mockTransferHelper;
    IAcrossSpokePoolV3 internal _mockAcrossSpokePool;
    MockAccountingChainGateway internal _mockAccountingChainGateway;
    MockEarningChainGateway internal _mockEarningChainGateway;

    AcrossAdapter internal _accountingChainAcrossAdapter;
    AcrossAdapter internal _earningChainAcrossAdapter;

    function _deployAcrossAdapter(
        bool isAccountingChain,
        address acrossSpokePool,
        address accessManager,
        address gateway,
        address transferHelper,
        address assetRegistry
    ) internal returns (AcrossAdapter) {
        AcrossAdapter acrossAdapter = new AcrossAdapter(
            isAccountingChain, acrossSpokePool, accessManager, gateway, transferHelper, assetRegistry
        );
        return acrossAdapter;
    }

    function _setupTokens() internal {
        _mockUsdtAccountingChain =
            IMockErc20(address(new MockNonStandardErc20("Test Accounting Chain USDT", "tUSDT", 6)));
        _mockGhoAccountingChain = IMockErc20(address(new MockNonStandardErc20("Test Accounting Chain GHO", "tGHO", 18)));
        _mockUsdtEarningChain = IMockErc20(address(new MockNonStandardErc20("Test Earning Chain USDT", "tUSDT", 6)));
        _mockGhoEarningChain = IMockErc20(address(new MockNonStandardErc20("Test Earning Chain GHO", "tGHO", 18)));
    }

    function _setupInfrastructure() internal {
        _mockTransferHelper = new MockTransferHelper();
        _mockAccessManager = new MockAccessManager(admin);
        _mockAssetRegistry = new MockAssetRegistry();
        _mockAccountingChainGateway = new MockAccountingChainGateway(address(_mockTransferHelper));
        _mockEarningChainGateway = new MockEarningChainGateway(address(_mockTransferHelper));
        _mockAcrossSpokePool = IAcrossSpokePoolV3(address(new MockAcrossSpokePool()));
    }

    function _setupAccountingChainAdapter() internal {
        _accountingChainAcrossAdapter = _deployAcrossAdapter(
            true,
            address(_mockAcrossSpokePool),
            address(_mockAccessManager),
            address(_mockAccountingChainGateway),
            address(_mockTransferHelper),
            address(_mockAssetRegistry)
        );
        IAcrossBridgeAdapter.AssetMapping[] memory assetMappings = new IAcrossBridgeAdapter.AssetMapping[](2);
        assetMappings[0] = IAcrossBridgeAdapter.AssetMapping({
            localAsset: address(_mockUsdtAccountingChain),
            destinationChainId: EARNING_CHAIN_ID,
            destinationChainAsset: address(_mockUsdtEarningChain)
        });
        assetMappings[1] = IAcrossBridgeAdapter.AssetMapping({
            localAsset: address(_mockGhoAccountingChain),
            destinationChainId: EARNING_CHAIN_ID,
            destinationChainAsset: address(_mockGhoEarningChain)
        });
        vm.prank(everyRoleAccount);
        _accountingChainAcrossAdapter.setDestinationChainAssets(assetMappings);
    }

    function _setupEarningChainAdapter() internal {
        _earningChainAcrossAdapter = _deployAcrossAdapter(
            false,
            address(_mockAcrossSpokePool),
            address(_mockAccessManager),
            address(_mockEarningChainGateway),
            address(_mockTransferHelper),
            address(_mockAssetRegistry)
        );
        IAcrossBridgeAdapter.AssetMapping[] memory assetMappings = new IAcrossBridgeAdapter.AssetMapping[](2);
        assetMappings[0] = IAcrossBridgeAdapter.AssetMapping({
            localAsset: address(_mockUsdtEarningChain),
            destinationChainId: ACCOUNTING_CHAIN_ID,
            destinationChainAsset: address(_mockUsdtAccountingChain)
        });
        assetMappings[1] = IAcrossBridgeAdapter.AssetMapping({
            localAsset: address(_mockGhoEarningChain),
            destinationChainId: ACCOUNTING_CHAIN_ID,
            destinationChainAsset: address(_mockGhoAccountingChain)
        });
        vm.prank(everyRoleAccount);
        _earningChainAcrossAdapter.setDestinationChainAssets(assetMappings);
    }

    function setUp() public virtual {
        _setupTokens();
        _setupInfrastructure();
        _setupAccountingChainAdapter();
        _setupEarningChainAdapter();

        // After both adapters are deployed, set the destination chain adapters
        vm.prank(everyRoleAccount);
        _accountingChainAcrossAdapter.setDestinationChainAdapter(EARNING_CHAIN_ID, address(_earningChainAcrossAdapter));
        vm.prank(everyRoleAccount);
        _earningChainAcrossAdapter.setDestinationChainAdapter(
            ACCOUNTING_CHAIN_ID, address(_accountingChainAcrossAdapter)
        );
    }

    function test_getSpokePool() public view {
        assertEq(_accountingChainAcrossAdapter.getSpokePool(), address(_mockAcrossSpokePool));
        assertEq(_earningChainAcrossAdapter.getSpokePool(), address(_mockAcrossSpokePool));
    }

    function test_getDestinationChainAsset() public view {
        assertEq(
            _accountingChainAcrossAdapter.getDestinationChainAsset(address(_mockUsdtAccountingChain), EARNING_CHAIN_ID),
            address(_mockUsdtEarningChain)
        );
        assertEq(
            _accountingChainAcrossAdapter.getDestinationChainAsset(address(_mockGhoAccountingChain), EARNING_CHAIN_ID),
            address(_mockGhoEarningChain)
        );
        assertEq(
            _earningChainAcrossAdapter.getDestinationChainAsset(address(_mockUsdtEarningChain), ACCOUNTING_CHAIN_ID),
            address(_mockUsdtAccountingChain)
        );
        assertEq(
            _earningChainAcrossAdapter.getDestinationChainAsset(address(_mockGhoEarningChain), ACCOUNTING_CHAIN_ID),
            address(_mockGhoAccountingChain)
        );
    }

    function test_supportsInterface() public view {
        assertEq(_accountingChainAcrossAdapter.supportsInterface(type(IAcrossV3Receiver).interfaceId), true);
        assertEq(_accountingChainAcrossAdapter.supportsInterface(type(IERC165).interfaceId), true);
        assertEq(_earningChainAcrossAdapter.supportsInterface(type(IAcrossV3Receiver).interfaceId), true);
        assertEq(_earningChainAcrossAdapter.supportsInterface(type(IERC165).interfaceId), true);
    }

    function test_rescueNative_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, uint256 amount)
        public
    {
        vm.assume(unauthorizedMsgSender != address(0));
        _mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(_accountingChainAcrossAdapter), IRescuableNative.rescueNative.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableNative(address(_accountingChainAcrossAdapter)).rescueNative(amount);
    }

    function test_rescueNative_getsExpectedAmountOfNativeToMsgSender(uint256 adapterBalance, uint256 amountToRescue)
        public
    {
        // Avoid fuzzing the msgSender address to avoid .call on precompiles and zero address.
        address msgSender = makeAddr("msgSender");

        adapterBalance = _boundNativeAmount(adapterBalance);
        amountToRescue = _boundNativeAmount(amountToRescue);
        vm.assume(adapterBalance >= amountToRescue);

        vm.deal(address(_accountingChainAcrossAdapter), adapterBalance);
        vm.assume(address(msgSender).balance == 0);

        vm.prank(msgSender);
        IRescuableNative(address(_accountingChainAcrossAdapter)).rescueNative(amountToRescue);

        assertEq(address(msgSender).balance, amountToRescue);
        assertEq(address(_accountingChainAcrossAdapter).balance, adapterBalance - amountToRescue);
    }

    function test_publishMessageToChainWithFeePayer_AccountingChainToEarningChain(
        uint256 feeAmount,
        uint256 amountToBridge,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp
    ) public {
        // Context: Accounting Chain -> Earning Chain no data is bridged
        uint32 fillDeadline = uint32(block.timestamp + 1000);
        feeAmount = _boundAssetAmount(address(_mockUsdtAccountingChain), feeAmount);
        amountToBridge = _boundAssetAmount(address(_mockUsdtAccountingChain), amountToBridge);

        uint256 totalInputAmount = amountToBridge + feeAmount;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdtAccountingChain), totalInputAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: amountToBridge});

        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: exclusivityDeadline
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockUsdtAccountingChain),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });

        bytes32 expectedMessageId = _buildMessageId(
            address(_accountingChainAcrossAdapter),
            EARNING_CHAIN_ID,
            address(_mockUsdtAccountingChain),
            totalInputAmount
        );
        bytes memory expectedCallData = _buildDepositV3ExpectCallData(
            DepositV3ExpectCallParams({
                depositor: address(_accountingChainAcrossAdapter),
                recipient: address(_earningChainAcrossAdapter),
                inputToken: address(_mockUsdtAccountingChain),
                outputToken: address(_mockUsdtEarningChain),
                inputAmount: totalInputAmount,
                outputAmount: amountToBridge,
                destinationChainId: EARNING_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: quoteTimestamp,
                fillDeadline: fillDeadline,
                exclusivityDeadline: exclusivityDeadline,
                message: "",
                messageId: expectedMessageId
            })
        );

        // Expect a call to the spoke pool to deposit the tokens and message
        vm.expectCall(address(_mockAcrossSpokePool), 0, expectedCallData);

        // The adapter needs to approve the spoke pool to spend the tokens
        vm.expectCall(
            address(_mockUsdtAccountingChain),
            0,
            abi.encodeCall(IERC20.approve, (address(_mockAcrossSpokePool), totalInputAmount))
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessagePublished(expectedMessageId);
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdtAccountingChain)), 0);
    }

    function test_publishMessageToChainWithFeePayer_EarningChainToAccountingChain(
        uint256 feeAmount,
        uint256 amountToBridge,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp
    ) public {
        // Context: Earning Chain -> Accounting Chain data is built on the Accounting Chain upon receiving the funds,
        // therefore no arbitrary data is bridged.
        uint32 fillDeadline = uint32(block.timestamp + 1000);
        feeAmount = _boundAssetAmount(address(_mockGhoEarningChain), feeAmount);
        amountToBridge = _boundAssetAmount(address(_mockGhoEarningChain), amountToBridge);

        uint256 totalInputAmount = amountToBridge + feeAmount;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockGhoEarningChain), totalInputAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockGhoEarningChain), amount: amountToBridge});

        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: exclusivityDeadline
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockGhoEarningChain),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });

        bytes32 expectedMessageId = _buildMessageId(
            address(_earningChainAcrossAdapter), ACCOUNTING_CHAIN_ID, address(_mockGhoEarningChain), totalInputAmount
        );
        bytes memory expectedCallData = _buildDepositV3ExpectCallData(
            DepositV3ExpectCallParams({
                depositor: address(_earningChainAcrossAdapter),
                recipient: address(_accountingChainAcrossAdapter),
                inputToken: address(_mockGhoEarningChain),
                outputToken: address(_mockGhoAccountingChain),
                inputAmount: totalInputAmount,
                outputAmount: amountToBridge,
                destinationChainId: ACCOUNTING_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: quoteTimestamp,
                fillDeadline: fillDeadline,
                exclusivityDeadline: exclusivityDeadline,
                message: "",
                messageId: expectedMessageId
            })
        );

        // Expect a call to the spoke pool to deposit the tokens and message
        vm.expectCall(address(_mockAcrossSpokePool), 0, expectedCallData);

        // The adapter needs to approve the spoke pool to spend the tokens
        vm.expectCall(
            address(_mockGhoEarningChain),
            0,
            abi.encodeCall(IERC20.approve, (address(_mockAcrossSpokePool), totalInputAmount))
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessagePublished(expectedMessageId);
        vm.prank(address(_mockEarningChainGateway));
        _earningChainAcrossAdapter.publishMessageToChainWithFeePayer(ACCOUNTING_CHAIN_ID, assets, "", bridgeParams);

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockGhoEarningChain)), 0);
    }

    function test_publishMessageToChainWithFeePayer_reverts_notGateway(address caller) public {
        vm.assume(caller != address(_mockAccountingChainGateway));
        vm.assume(caller != address(_mockEarningChainGateway));

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: 1000000000});

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdtAccountingChain),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        vm.expectRevert(Errors.OnlyGateway.selector);
        vm.prank(caller);
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_arbitraryDataNotAllowed() public {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: 1000000000});

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdtAccountingChain),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode("")
        });

        bytes memory data = abi.encode(hex"c0ffee");
        vm.expectRevert(abi.encodeWithSelector(IBridgeAdapter.ArbitraryDataNotAllowed.selector));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, data, bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_invalidAssetsLength() public {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](2);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: 1000000000});
        assets[1] = IBridgeAdapter.BridgeAsset({asset: address(_mockGhoAccountingChain), amount: 1000000000});

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdtAccountingChain),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.InvalidAssetsLength.selector, 1, 2));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_bridgeAmountIsZero() public {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: 0});

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdtAccountingChain),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_invalidFeeToken() public {
        // Context: bridge USDT, but set fee token to GHO
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: 1000000000});

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockGhoAccountingChain),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                IAcrossBridgeAdapter.InvalidFeeToken.selector,
                address(_mockUsdtAccountingChain),
                address(_mockGhoAccountingChain)
            )
        );
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_invalidSpokePool() public {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: 1000000000});

        address invalidSpokePool = makeAddr("invalidSpokePool");
        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: invalidSpokePool,
            quoteTimestamp: 0,
            fillDeadline: 0,
            exclusiveRelayer: address(0),
            exclusivityDeadline: 0
        });

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdtAccountingChain),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IAcrossBridgeAdapter.InvalidSpokePool.selector, address(_mockAcrossSpokePool), invalidSpokePool
            )
        );
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_invalidFillDeadline() public {
        vm.warp(block.timestamp + 365 days);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: 1000000000});

        uint32 fillDeadline = uint32(block.timestamp - 1);
        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: 0,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: 0
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdtAccountingChain),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });
        vm.expectRevert(abi.encodeWithSelector(IAcrossBridgeAdapter.FillDeadlineExpired.selector, fillDeadline));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_insufficientFundsInTransferHelper(
        uint256 feeAmount,
        uint256 amountToBridge,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp
    ) public {
        uint32 fillDeadline = uint32(block.timestamp + 1000);
        feeAmount = _boundAssetAmount(address(_mockUsdtAccountingChain), feeAmount);
        amountToBridge = _boundAssetAmount(address(_mockUsdtAccountingChain), amountToBridge);

        uint256 totalInputAmount = amountToBridge + feeAmount;
        vm.assume(totalInputAmount > 0);
        uint256 insufficientAmount = totalInputAmount - 1;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdtAccountingChain), insufficientAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: amountToBridge});

        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: exclusivityDeadline
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockUsdtAccountingChain),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);

        // Check that the TransferHelper still has the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdtAccountingChain)), insufficientAmount);
    }

    function test_publishMessageToChainWithFeePayer_reverts_messageIdCollision(
        uint256 feeAmount,
        uint256 amountToBridge,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp
    ) public {
        uint32 fillDeadline = uint32(block.timestamp + 1000);
        feeAmount = _boundAssetAmount(address(_mockGhoEarningChain), feeAmount);
        amountToBridge = _boundAssetAmount(address(_mockGhoEarningChain), amountToBridge);

        uint256 totalInputAmount = amountToBridge + feeAmount;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockGhoEarningChain), totalInputAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockGhoEarningChain), amount: amountToBridge});

        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: exclusivityDeadline
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockGhoEarningChain),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });

        bytes32 expectedMessageId = _buildMessageId(
            address(_earningChainAcrossAdapter), ACCOUNTING_CHAIN_ID, address(_mockGhoEarningChain), totalInputAmount
        );
        bytes memory expectedCallData = _buildDepositV3ExpectCallData(
            DepositV3ExpectCallParams({
                depositor: address(_earningChainAcrossAdapter),
                recipient: address(_accountingChainAcrossAdapter),
                inputToken: address(_mockGhoEarningChain),
                outputToken: address(_mockGhoAccountingChain),
                inputAmount: totalInputAmount,
                outputAmount: amountToBridge,
                destinationChainId: ACCOUNTING_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: quoteTimestamp,
                fillDeadline: fillDeadline,
                exclusivityDeadline: exclusivityDeadline,
                message: "",
                messageId: expectedMessageId
            })
        );

        // Expect a call to the spoke pool to deposit the tokens and message
        vm.expectCall(address(_mockAcrossSpokePool), 0, expectedCallData);

        // The adapter needs to approve the spoke pool to spend the tokens
        vm.expectCall(
            address(_mockGhoEarningChain),
            0,
            abi.encodeCall(IERC20.approve, (address(_mockAcrossSpokePool), totalInputAmount))
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessagePublished(expectedMessageId);
        vm.prank(address(_mockEarningChainGateway));
        _earningChainAcrossAdapter.publishMessageToChainWithFeePayer(ACCOUNTING_CHAIN_ID, assets, "", bridgeParams);

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockGhoEarningChain)), 0);

        // Bridge the same amount for the same token to the same destination chain within the same block
        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockGhoEarningChain), totalInputAmount);
        vm.expectRevert(IAcrossBridgeAdapter.MessageAlreadyPublished.selector);
        vm.prank(address(_mockEarningChainGateway));
        _earningChainAcrossAdapter.publishMessageToChainWithFeePayer(ACCOUNTING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_destinationAssetNotSupported(
        uint256 feeAmount,
        uint256 amountToBridge,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp
    ) public {
        // Unset the Accounting Chain's GHO address on the Earning Chain Across Adapter
        vm.prank(everyRoleAccount);
        IAcrossBridgeAdapter.AssetMapping[] memory assetMappings = new IAcrossBridgeAdapter.AssetMapping[](1);
        assetMappings[0] = IAcrossBridgeAdapter.AssetMapping({
            localAsset: address(_mockGhoEarningChain),
            destinationChainId: ACCOUNTING_CHAIN_ID,
            destinationChainAsset: address(0)
        });
        _earningChainAcrossAdapter.setDestinationChainAssets(assetMappings);

        uint32 fillDeadline = uint32(block.timestamp + 1000);
        feeAmount = _boundAssetAmount(address(_mockGhoEarningChain), feeAmount);
        amountToBridge = _boundAssetAmount(address(_mockGhoEarningChain), amountToBridge);

        uint256 totalInputAmount = amountToBridge + feeAmount;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockGhoEarningChain), totalInputAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockGhoEarningChain), amount: amountToBridge});

        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: exclusivityDeadline
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockGhoEarningChain),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });

        bytes32 expectedMessageId = _buildMessageId(
            address(_earningChainAcrossAdapter), ACCOUNTING_CHAIN_ID, address(_mockGhoEarningChain), totalInputAmount
        );
        bytes memory expectedCallData = _buildDepositV3ExpectCallData(
            DepositV3ExpectCallParams({
                depositor: address(_earningChainAcrossAdapter),
                recipient: address(_accountingChainAcrossAdapter),
                inputToken: address(_mockGhoEarningChain),
                outputToken: address(_mockGhoAccountingChain),
                inputAmount: totalInputAmount,
                outputAmount: amountToBridge,
                destinationChainId: ACCOUNTING_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: quoteTimestamp,
                fillDeadline: fillDeadline,
                exclusivityDeadline: exclusivityDeadline,
                message: "",
                messageId: expectedMessageId
            })
        );

        // Check that the spoke pool was not called to deposit the tokens and data
        vm.expectCall(address(_mockAcrossSpokePool), 0, expectedCallData, 0);

        // Check that GHO was not called to approve the spoke pool to spend the tokens
        // Later we check that the approval was reverted
        vm.expectCall(
            address(_mockGhoEarningChain),
            0,
            abi.encodeCall(IERC20.approve, (address(_mockAcrossSpokePool), totalInputAmount))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IAcrossBridgeAdapter.UnsupportedDestinationChainAsset.selector,
                address(_mockGhoEarningChain),
                ACCOUNTING_CHAIN_ID
            )
        );
        vm.prank(address(_mockEarningChainGateway));
        _earningChainAcrossAdapter.publishMessageToChainWithFeePayer(ACCOUNTING_CHAIN_ID, assets, "", bridgeParams);

        // Check that the TransferHelper still holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockGhoEarningChain)), totalInputAmount);

        // Check that the approval was reverted
        assertEq(
            IERC20(address(_mockGhoEarningChain))
                .allowance(address(_earningChainAcrossAdapter), address(_mockAcrossSpokePool)),
            0
        );
    }

    function test_handleV3AcrossMessage_onAccountingChain(uint256 bridgedAmount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdtAccountingChain));
        bridgedAmount = _boundAssetAmount(address(_mockUsdtAccountingChain), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdtAccountingChain.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        // Message ID is built on the source chain, so use the Earning chain USDT address and set Accounting chain ID as
        // destination chainId.
        bytes32 messageId = _buildMessageId(
            address(_earningChainAcrossAdapter), ACCOUNTING_CHAIN_ID, address(_mockUsdtEarningChain), bridgedAmount
        );

        AcrossAdapter.AcrossPacket memory acrossPacket =
            AcrossAdapter.AcrossPacket({sourceChainId: EARNING_CHAIN_ID, messageId: messageId});

        bytes memory expectedDataIn = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.DECREMENT_BALANCE_SNAPSHOT,
                data: abi.encode(
                    IChainGateway.DecrementBalanceSnapshotMessage({
                        amountRay: bridgedAmount.assetDecimalsToRay(address(_mockUsdtAccountingChain))
                    })
                )
            })
        );

        vm.expectCall(
            address(_mockAccountingChainGateway),
            0,
            abi.encodeCall(
                IChainGateway.receiveMessage, (EARNING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), expectedDataIn)
            )
        );

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: bridgedAmount});
        vm.expectCall(
            address(_mockAccountingChainGateway), 0, abi.encodeCall(IChainGateway.receiveMessage, (0, assets, ""))
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessageReceived(messageId);
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdtAccountingChain), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the TransferHelper moved the assets to the Accounting Chain Gateway
        assertEq(_mockUsdtAccountingChain.balanceOf(address(_accountingChainAcrossAdapter)), 0);
        assertEq(_mockUsdtAccountingChain.balanceOf(address(_mockTransferHelper)), 0);
        assertEq(_mockUsdtAccountingChain.balanceOf(address(_mockAccountingChainGateway)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_onEarningChain(uint256 bridgedAmount) public {
        // Context: there is no need to forward a message to the Gateway to decrement balance snapshot.
        bridgedAmount = _boundAssetAmount(address(_mockGhoEarningChain), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockGhoEarningChain.mint(address(_earningChainAcrossAdapter), bridgedAmount);

        bytes32 messageId = _buildMessageId(
            address(_earningChainAcrossAdapter), EARNING_CHAIN_ID, address(_mockGhoEarningChain), bridgedAmount
        );

        AcrossAdapter.AcrossPacket memory acrossPacket =
            AcrossAdapter.AcrossPacket({sourceChainId: ACCOUNTING_CHAIN_ID, messageId: messageId});

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockGhoEarningChain), amount: bridgedAmount});
        vm.expectCall(
            address(_mockEarningChainGateway), 0, abi.encodeCall(IChainGateway.receiveMessage, (0, assets, ""))
        );

        // Check that gateway is not called to decrement the balance snapshot
        bytes memory decrementBalanceSnapshotMessage = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.DECREMENT_BALANCE_SNAPSHOT,
                data: abi.encode(
                    IChainGateway.DecrementBalanceSnapshotMessage({
                        amountRay: bridgedAmount.assetDecimalsToRay(address(_mockGhoEarningChain))
                    })
                )
            })
        );
        vm.expectCall(
            address(_mockEarningChainGateway),
            0,
            abi.encodeCall(
                IChainGateway.receiveMessage, (0, new IBridgeAdapter.BridgeAsset[](0), decrementBalanceSnapshotMessage)
            ),
            0
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessageReceived(messageId);
        vm.prank(address(_mockAcrossSpokePool));
        _earningChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockGhoEarningChain), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the TransferHelper moved the assets to the Earning Chain Gateway
        assertEq(_mockGhoEarningChain.balanceOf(address(_earningChainAcrossAdapter)), 0);
        assertEq(_mockGhoEarningChain.balanceOf(address(_mockTransferHelper)), 0);
        assertEq(_mockGhoEarningChain.balanceOf(address(_mockEarningChainGateway)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_callerNotSpokePool(address caller) public {
        vm.assume(caller != address(_mockAcrossSpokePool));
        vm.expectRevert(
            abi.encodeWithSelector(IAcrossBridgeAdapter.OnlySpokePool.selector, address(_mockAcrossSpokePool))
        );
        AcrossAdapter.AcrossPacket memory acrossPacket =
            AcrossAdapter.AcrossPacket({sourceChainId: ACCOUNTING_CHAIN_ID, messageId: keccak256(abi.encode(""))});
        bytes memory message = abi.encode(acrossPacket);
        vm.prank(caller);
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdtAccountingChain), 1000000000, address(0), message
        );
    }

    function test_handleV3AcrossMessage_revert_ifInvalidAcrossPacket(uint256 bridgedAmount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdtAccountingChain));
        _mockAssetRegistry.mockToDisallowAssetDepositsIntoAllocator(address(_mockUsdtAccountingChain));
        bridgedAmount = _boundAssetAmount(address(_mockUsdtAccountingChain), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdtAccountingChain.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        bytes memory invalidAcrossPacket = abi.encode(hex"c0DDee");

        vm.prank(address(_mockAcrossSpokePool));
        vm.expectRevert();
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdtAccountingChain), bridgedAmount, address(0), invalidAcrossPacket
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdtAccountingChain.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_handlesFundsHandlingFailure(uint256 bridgedAmount) public {
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdtAccountingChain));
        bridgedAmount = _boundAssetAmount(address(_mockUsdtAccountingChain), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdtAccountingChain.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        bytes32 messageId = _buildMessageId(
            address(_earningChainAcrossAdapter), EARNING_CHAIN_ID, address(_mockUsdtAccountingChain), bridgedAmount
        );
        AcrossAdapter.AcrossPacket memory acrossPacket =
            AcrossAdapter.AcrossPacket({sourceChainId: EARNING_CHAIN_ID, messageId: messageId});

        bytes memory error = abi.encode("test");

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessageReceived(messageId);
        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.TokenReceptionFailed(
            messageId, EARNING_CHAIN_ID, address(_mockUsdtAccountingChain), bridgedAmount
        );
        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.BridgedFundsProcessingFailed(messageId, EARNING_CHAIN_ID, abi.encode(acrossPacket), error);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: bridgedAmount});
        vm.mockCallRevert(
            address(_mockAccountingChainGateway), abi.encodeCall(IChainGateway.receiveMessage, (0, assets, "")), error
        );
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdtAccountingChain), bridgedAmount, address(0), abi.encode(acrossPacket)
        );
    }

    function test_replayFundsReceiving(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdtAccountingChain), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdtAccountingChain.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: bridgedAmount});

        vm.expectCall(
            address(_mockUsdtAccountingChain),
            abi.encodeCall(IERC20.transfer, (address(_mockTransferHelper), bridgedAmount))
        );
        vm.expectCall(
            address(_mockAccountingChainGateway), abi.encodeCall(IChainGateway.receiveMessage, (0, assets, ""))
        );

        vm.prank(everyRoleAccount);
        _accountingChainAcrossAdapter.replayFundsReceiving(assets);

        // Check the funds have moved from the TransferHelper to the Accounting Chain Gateway
        assertEq(_mockUsdtAccountingChain.balanceOf(address(_accountingChainAcrossAdapter)), 0);
        assertEq(_mockUsdtAccountingChain.balanceOf(address(_mockTransferHelper)), 0);
        assertEq(_mockUsdtAccountingChain.balanceOf(address(_mockAccountingChainGateway)), bridgedAmount);
    }

    function test_replayFundsReceiving_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 bridgedAmount
    ) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdtAccountingChain), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdtAccountingChain.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdtAccountingChain), amount: bridgedAmount});
        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedMsgSender,
                address(_accountingChainAcrossAdapter),
                bytes4(AcrossAdapter.replayFundsReceiving.selector)
            ),
            abi.encode(false)
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        _accountingChainAcrossAdapter.replayFundsReceiving(assets);
    }

    function _buildMessageId(address acrossAdapter, uint256 destinationChainId, address asset, uint256 amount)
        internal
        view
        returns (bytes32)
    {
        return EfficientHashLib.hash(
            abi.encode(block.chainid, block.timestamp, acrossAdapter, destinationChainId, asset, amount)
        );
    }

    function _buildDepositV3ExpectCallData(DepositV3ExpectCallParams memory p) internal view returns (bytes memory) {
        AcrossAdapter.AcrossPacket memory expectedAcrossPacket =
            AcrossAdapter.AcrossPacket({sourceChainId: block.chainid, messageId: p.messageId});

        return abi.encodeCall(
            IAcrossSpokePoolV3.depositV3,
            (
                p.depositor,
                p.recipient,
                p.inputToken,
                p.outputToken,
                p.inputAmount,
                p.outputAmount,
                p.destinationChainId,
                p.exclusiveRelayer,
                p.quoteTimestamp,
                p.fillDeadline,
                p.exclusivityDeadline,
                abi.encode(expectedAcrossPacket)
            )
        );
    }
}
