// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AcrossAdapter} from "src/bridging/AcrossAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";

import {IAcrossSpokePoolV3} from "src/dependencies/across/IAcrossSpokePoolV3.sol";
import {IAcrossV3Receiver} from "src/dependencies/across/IAcrossV3Receiver.sol";
import {IAcrossBridgeAdapter} from "src/interfaces/IAcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";
import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAccountingChainGateway} from "test/mocks/MockAccountingChainGateway.sol";
import {MockAcrossSpokePool} from "test/mocks/MockAcrossSpokePool.sol";
import {MockEarningChainGateway} from "test/mocks/MockEarningChainGateway.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract AcrossAdapterTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMockErc20;

    struct SignBridgeDataParams {
        uint256 signerPk;
        uint256 destinationChainId;
        address verifyingContractAddress;
        uint256 sourceChainId;
        uint256 signatureNonce;
        uint256 signatureExpirationTs;
        address asset;
        uint256 amount;
    }

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
        uint256 signatureNonce;
        uint256 signatureExpirationTs;
        bytes signature;
        bytes32 messageId;
    }

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;
    uint256 internal DEFAULT_GAS_LIMIT = 100000;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    // Signs messages published on the Accounting chain
    address earningChainSigner;
    uint256 earningChainSignerPk;
    // Signs messages published on the Earning chain
    address accountingChainSigner;
    uint256 accountingChainSignerPk;
    // Invalid signer used to make sure invalid signatures are rejected
    address invalidSigner;
    uint256 invalidSignerPk;

    MockAccessManager internal _mockAccessManager;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    MockTransferHelper internal _mockTransferHelper;
    IAcrossSpokePoolV3 internal _mockAcrossSpokePool;
    MockAccountingChainGateway internal _mockAccountingChainGateway;
    MockEarningChainGateway internal _mockEarningChainGateway;

    AcrossAdapter internal _accountingChainAcrossAdapter;
    AcrossAdapter internal _earningChainAcrossAdapter;

    function _deployAcrossAdapter(
        address acrossSpokePool,
        address accessManager,
        address gateway,
        address transferHelper
    ) internal returns (AcrossAdapter) {
        AcrossAdapter acrossAdapter = new AcrossAdapter(acrossSpokePool, accessManager, gateway, transferHelper);
        return acrossAdapter;
    }

    function _setupTokens() internal {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
    }

    function _setupInfrastructure() internal {
        _mockTransferHelper = new MockTransferHelper();
        _mockAccessManager = new MockAccessManager(admin);
        _mockAccountingChainGateway = new MockAccountingChainGateway(address(_mockTransferHelper));
        _mockEarningChainGateway = new MockEarningChainGateway(address(_mockTransferHelper));
        _mockAcrossSpokePool = IAcrossSpokePoolV3(address(new MockAcrossSpokePool()));
    }

    function _setupAccountingChainAdapter() internal {
        _accountingChainAcrossAdapter = _deployAcrossAdapter(
            address(_mockAcrossSpokePool),
            address(_mockAccessManager),
            address(_mockAccountingChainGateway),
            address(_mockTransferHelper)
        );
        vm.prank(everyRoleAccount);
        _accountingChainAcrossAdapter.setSigner(accountingChainSigner, true);
    }

    function _setupEarningChainAdapter() internal {
        _earningChainAcrossAdapter = _deployAcrossAdapter(
            address(_mockAcrossSpokePool),
            address(_mockAccessManager),
            address(_mockEarningChainGateway),
            address(_mockTransferHelper)
        );
        vm.prank(everyRoleAccount);
        _earningChainAcrossAdapter.setSigner(earningChainSigner, true);
    }

    function _setupSigners() internal {
        (earningChainSigner, earningChainSignerPk) = makeAddrAndKey("earningChainSigner");
        (accountingChainSigner, accountingChainSignerPk) = makeAddrAndKey("accountingChainSigner");
        (invalidSigner, invalidSignerPk) = makeAddrAndKey("invalidSigner");
    }

    function setUp() public virtual {
        _setupSigners();
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

    function test_getSigningPayload() public view {
        bytes32 signingPayload = _accountingChainAcrossAdapter.getSigningPayload(
            EARNING_CHAIN_ID, 1, 1000000000, address(_mockUsdt), 1000000000
        );
        bytes32 expectedSigningPayload = _getSigningPayload(
            block.chainid,
            address(_accountingChainAcrossAdapter),
            EARNING_CHAIN_ID,
            1,
            1000000000,
            address(_mockUsdt),
            1000000000
        );
        assertEq(signingPayload, expectedSigningPayload);
        assertEq(signingPayload, 0x88f0be843cc312d468fe49389abba17ba35fc5b174db45bc9b55b94898a7971a);

        signingPayload = _earningChainAcrossAdapter.getSigningPayload(
            ACCOUNTING_CHAIN_ID, 1, 1000000000, address(_mockUsdt), 1000000000
        );
        expectedSigningPayload = _getSigningPayload(
            block.chainid,
            address(_earningChainAcrossAdapter),
            ACCOUNTING_CHAIN_ID,
            1,
            1000000000,
            address(_mockUsdt),
            1000000000
        );
        assertEq(signingPayload, expectedSigningPayload);
        assertEq(signingPayload, 0x9c0123550e3779e99e782d1ffd80954c91bad4775e2b7fda191e9ec8c272127a);
    }

    function test_isSigner() public {
        assertEq(_accountingChainAcrossAdapter.isSigner(accountingChainSigner), true);
        assertEq(_earningChainAcrossAdapter.isSigner(earningChainSigner), true);
        address noneExistingSigner = makeAddr("NONE_EXISTING_SIGNER");
        assertEq(_accountingChainAcrossAdapter.isSigner(noneExistingSigner), false);
        assertEq(_earningChainAcrossAdapter.isSigner(noneExistingSigner), false);
    }

    function test_supportsInterface() public view {
        assertEq(_accountingChainAcrossAdapter.supportsInterface(type(IAcrossV3Receiver).interfaceId), true);
        assertEq(_accountingChainAcrossAdapter.supportsInterface(type(IERC165).interfaceId), true);
        assertEq(_earningChainAcrossAdapter.supportsInterface(type(IAcrossV3Receiver).interfaceId), true);
        assertEq(_earningChainAcrossAdapter.supportsInterface(type(IERC165).interfaceId), true);
    }

    function test_invalidateNonce(uint256 nonce) public {
        vm.prank(earningChainSigner);
        vm.expectEmit(true, true, true, true);
        emit IAcrossBridgeAdapter.NonceConsumed(earningChainSigner, nonce);
        _earningChainAcrossAdapter.invalidateNonce(earningChainSigner, nonce);
        assertTrue(_earningChainAcrossAdapter.isNonceUsed(earningChainSigner, nonce));

        vm.prank(accountingChainSigner);
        vm.expectEmit(true, true, true, true);
        emit IAcrossBridgeAdapter.NonceConsumed(accountingChainSigner, nonce);
        _accountingChainAcrossAdapter.invalidateNonce(accountingChainSigner, nonce);
        assertTrue(_accountingChainAcrossAdapter.isNonceUsed(accountingChainSigner, nonce));
    }

    function test_invalidateNonce_reverts_ifNonceIsAlreadyConsumed(uint256 nonce) public {
        vm.prank(earningChainSigner);
        _earningChainAcrossAdapter.invalidateNonce(earningChainSigner, nonce);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.SignatureNonceAlreadyConsumed.selector, earningChainSigner, nonce)
        );
        vm.prank(earningChainSigner);
        _earningChainAcrossAdapter.invalidateNonce(earningChainSigner, nonce);
    }

    function test_invalidateNonce_reverts_ifMsgSenderIsNotSigner_earningChain(address signer, uint256 nonce) public {
        vm.assume(signer != address(this));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorized.selector));
        _earningChainAcrossAdapter.invalidateNonce(signer, nonce);
    }

    function test_invalidateNonce_reverts_ifMsgSenderIsNotAuthorized_earningChain(address signer, uint256 nonce)
        public
    {
        vm.assume(signer != earningChainSigner);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorized.selector));
        _earningChainAcrossAdapter.invalidateNonce(signer, nonce);
    }

    function test_invalidateNonce_reverts_ifMsgSenderIsNotAuthorized_accountingChain(address signer, uint256 nonce)
        public
    {
        vm.assume(signer != accountingChainSigner);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorized.selector));
        _accountingChainAcrossAdapter.invalidateNonce(signer, nonce);
    }

    function test_publishMessageToChainWithFeePayer_AccountingChainToEarningChain(
        uint256 feeAmount,
        uint256 amountToBridge,
        uint256 signatureNonce,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp
    ) public {
        // Context: Accounting Chain -> Earning Chain no data is bridged
        uint32 fillDeadline = uint32(block.timestamp + 1000);
        uint32 signatureExpirationTs = uint32(block.timestamp + 2000);
        feeAmount = _boundAssetAmount(address(_mockUsdt), feeAmount);
        amountToBridge = _boundAssetAmount(address(_mockUsdt), amountToBridge);

        uint256 totalInputAmount = amountToBridge + feeAmount;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), totalInputAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: amountToBridge});

        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: earningChainSignerPk,
                destinationChainId: EARNING_CHAIN_ID,
                verifyingContractAddress: address(_earningChainAcrossAdapter),
                sourceChainId: block.chainid,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: amountToBridge
            })
        );

        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: exclusivityDeadline,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockUsdt),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });

        bytes memory expectedCallData = _buildDepositV3ExpectCallData(
            DepositV3ExpectCallParams({
                depositor: address(_accountingChainAcrossAdapter),
                recipient: address(_earningChainAcrossAdapter),
                inputToken: address(_mockUsdt),
                outputToken: address(_mockUsdt),
                inputAmount: totalInputAmount,
                outputAmount: amountToBridge,
                destinationChainId: EARNING_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: quoteTimestamp,
                fillDeadline: fillDeadline,
                exclusivityDeadline: exclusivityDeadline,
                message: "",
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                signature: signature,
                messageId: keccak256(signature)
            })
        );

        // Expect a call to the spoke pool to deposit the tokens and message
        vm.expectCall(address(_mockAcrossSpokePool), 0, expectedCallData);

        // The adapter needs to approve the spoke pool to spend the tokens
        vm.expectCall(
            address(_mockUsdt), 0, abi.encodeCall(IERC20.approve, (address(_mockAcrossSpokePool), totalInputAmount))
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessagePublished(keccak256(signature));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), 0);
    }

    function test_publishMessageToChainWithFeePayer_EarningChainToAccountingChain(
        uint256 feeAmount,
        uint256 amountToBridge,
        uint256 signatureNonce,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp
    ) public {
        // Context: Earning Chain -> Accounting Chain data is bridged
        uint32 fillDeadline = uint32(block.timestamp + 1000);
        uint32 signatureExpirationTs = uint32(block.timestamp + 2000);
        feeAmount = _boundAssetAmount(address(_mockGho), feeAmount);
        amountToBridge = _boundAssetAmount(address(_mockGho), amountToBridge);

        uint256 totalInputAmount = amountToBridge + feeAmount;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockGho), totalInputAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockGho), amount: amountToBridge});

        bytes memory dataToBridge = abi.encode(hex"c0ffee");

        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                destinationChainId: ACCOUNTING_CHAIN_ID,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: block.chainid,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockGho),
                amount: amountToBridge
            })
        );

        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: exclusivityDeadline,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockGho),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });

        bytes memory expectedCallData = _buildDepositV3ExpectCallData(
            DepositV3ExpectCallParams({
                depositor: address(_earningChainAcrossAdapter),
                recipient: address(_accountingChainAcrossAdapter),
                inputToken: address(_mockGho),
                outputToken: address(_mockGho),
                inputAmount: totalInputAmount,
                outputAmount: amountToBridge,
                destinationChainId: ACCOUNTING_CHAIN_ID,
                exclusiveRelayer: address(0),
                quoteTimestamp: quoteTimestamp,
                fillDeadline: fillDeadline,
                exclusivityDeadline: exclusivityDeadline,
                message: dataToBridge,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                signature: signature,
                messageId: keccak256(signature)
            })
        );

        // Expect a call to the spoke pool to deposit the tokens and message
        vm.expectCall(address(_mockAcrossSpokePool), 0, expectedCallData);

        // The adapter needs to approve the spoke pool to spend the tokens
        vm.expectCall(
            address(_mockGho), 0, abi.encodeCall(IERC20.approve, (address(_mockAcrossSpokePool), totalInputAmount))
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessagePublished(keccak256(signature));
        vm.prank(address(_mockEarningChainGateway));
        _earningChainAcrossAdapter.publishMessageToChainWithFeePayer(
            ACCOUNTING_CHAIN_ID, assets, dataToBridge, bridgeParams
        );

        // Check that the TransferHelper no longer holds the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockGho)), 0);
    }

    function test_publishMessageToChainWithFeePayer_reverts_invalidAssetsLength() public {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](2);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: 1000000000});
        assets[1] = IBridgeAdapter.BridgeAsset({asset: address(_mockGho), amount: 1000000000});

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdt),
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
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: 0});

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdt),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ZeroAmount.selector));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_invalidFeeToken() public {
        // Context: bridge USDT, but set fee token to GHO
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: 1000000000});

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockGho),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: ""
        });
        vm.expectRevert(
            abi.encodeWithSelector(IAcrossBridgeAdapter.InvalidFeeToken.selector, address(_mockUsdt), address(_mockGho))
        );
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_invalidSpokePool() public {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: 1000000000});

        address invalidSpokePool = makeAddr("invalidSpokePool");
        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: invalidSpokePool,
            quoteTimestamp: 0,
            fillDeadline: 0,
            exclusiveRelayer: address(0),
            exclusivityDeadline: 0,
            signatureNonce: 0,
            signatureExpirationTs: 0,
            signature: ""
        });

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdt),
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

    function test_publishMessageToChainWithFeePayer_reverts_invalidSignatureExpirationTs() public {
        vm.warp(365 days);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: 1000000000});

        uint32 signatureExpirationTs = uint32(block.timestamp - 1);
        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: 0,
            fillDeadline: 0,
            exclusiveRelayer: address(0),
            exclusivityDeadline: 0,
            signatureNonce: 0,
            signatureExpirationTs: signatureExpirationTs,
            signature: ""
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdt),
            feeAmount: 0,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SignatureTimestampExpired.selector, signatureExpirationTs));
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);
    }

    function test_publishMessageToChainWithFeePayer_reverts_invalidFillDeadline() public {
        vm.warp(365 days);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: 1000000000});

        uint32 fillDeadline = uint32(block.timestamp - 1);
        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: 0,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: 0,
            signatureNonce: 0,
            signatureExpirationTs: uint32(block.timestamp + 2000),
            signature: ""
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(this),
            feeToken: address(_mockUsdt),
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
        uint256 signatureNonce,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp
    ) public {
        uint32 fillDeadline = uint32(block.timestamp + 1000);
        uint32 signatureExpirationTs = uint32(block.timestamp + 2000);
        feeAmount = _boundAssetAmount(address(_mockUsdt), feeAmount);
        amountToBridge = _boundAssetAmount(address(_mockUsdt), amountToBridge);

        uint256 totalInputAmount = amountToBridge + feeAmount;
        vm.assume(totalInputAmount > 0);
        uint256 insufficientAmount = totalInputAmount - 1;

        // Airdrop tokens to the TransferHelper as they would be pushed there from feePayer and Allocator
        _mockTransferHelper.mockAsset(address(_mockUsdt), insufficientAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: amountToBridge});

        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: earningChainSignerPk,
                destinationChainId: EARNING_CHAIN_ID,
                verifyingContractAddress: address(_earningChainAcrossAdapter),
                sourceChainId: block.chainid,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: amountToBridge
            })
        );

        IAcrossBridgeAdapter.AcrossBridgeParams memory acrossBridgeParams = IAcrossBridgeAdapter.AcrossBridgeParams({
            spokePoolAddress: address(_mockAcrossSpokePool),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusiveRelayer: address(0),
            exclusivityDeadline: exclusivityDeadline,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature
        });
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: everyRoleAccount,
            feeToken: address(_mockUsdt),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: DEFAULT_GAS_LIMIT,
            data: abi.encode(acrossBridgeParams)
        });
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(address(_mockAccountingChainGateway));
        _accountingChainAcrossAdapter.publishMessageToChainWithFeePayer(EARNING_CHAIN_ID, assets, "", bridgeParams);

        // Check that the TransferHelper still has the assets
        assertEq(_mockTransferHelper.getBalance(address(_mockUsdt)), insufficientAmount);
    }

    function test_handleV3AcrossMessage_onAccountingChain(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectCall(
            address(_mockAccountingChainGateway),
            0,
            abi.encodeCall(
                IChainGateway.receiveMessage, (EARNING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), bridgedMessage)
            )
        );

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: bridgedAmount});
        vm.expectCall(
            address(_mockAccountingChainGateway), 0, abi.encodeCall(IChainGateway.receiveMessage, (0, assets, ""))
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessageReceived(messageId);
        vm.expectEmit(true, true, true, true);
        emit IAcrossBridgeAdapter.NonceConsumed(accountingChainSigner, signatureNonce);
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the nonce is consumed
        assertEq(_accountingChainAcrossAdapter.isNonceUsed(accountingChainSigner, signatureNonce), true);

        // Check that the TransferHelper moved the assets to the Accounting Chain Gateway
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), 0);
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), 0);
        assertEq(_mockUsdt.balanceOf(address(_mockAccountingChainGateway)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_onEarningChain(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockGho), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockGho.mint(address(_earningChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: earningChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_earningChainAcrossAdapter),
                sourceChainId: ACCOUNTING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockGho),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = "";
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: ACCOUNTING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockGho), amount: bridgedAmount});
        vm.expectCall(
            address(_mockEarningChainGateway), 0, abi.encodeCall(IChainGateway.receiveMessage, (0, assets, ""))
        );

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.MessageReceived(messageId);
        vm.expectEmit(true, true, true, true);
        emit IAcrossBridgeAdapter.NonceConsumed(earningChainSigner, signatureNonce);
        vm.prank(address(_mockAcrossSpokePool));
        _earningChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockGho), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the nonce is consumed
        assertEq(_earningChainAcrossAdapter.isNonceUsed(earningChainSigner, signatureNonce), true);

        // Check that the TransferHelper moved the assets to the Earning Chain Gateway
        assertEq(_mockGho.balanceOf(address(_earningChainAcrossAdapter)), 0);
        assertEq(_mockGho.balanceOf(address(_mockTransferHelper)), 0);
        assertEq(_mockGho.balanceOf(address(_mockEarningChainGateway)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_callerNotSpokePool(address caller) public {
        vm.assume(caller != address(_mockAcrossSpokePool));
        vm.expectRevert(
            abi.encodeWithSelector(IAcrossBridgeAdapter.OnlySpokePool.selector, address(_mockAcrossSpokePool))
        );
        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: "",
            sourceChainId: ACCOUNTING_CHAIN_ID,
            signatureNonce: 1,
            signatureExpirationTs: uint32(block.timestamp + 2000),
            signature: "",
            messageId: keccak256(abi.encode(""))
        });
        bytes memory message = abi.encode(acrossPacket);
        vm.prank(caller);
        _accountingChainAcrossAdapter.handleV3AcrossMessage(address(_mockUsdt), 1000000000, address(0), message);
    }

    function test_handleV3AcrossMessage_reverts_expiredSignatureTimestamp(uint256 bridgedAmount) public {
        vm.warp(365 days);
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp - 1);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SignatureTimestampExpired.selector, signatureExpirationTs));
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_nonWhitelistedSigner(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: invalidSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidSignature.selector));
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_signatureOverWrongChainId(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: 8453,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidSignature.selector));
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_signatureOverWrongNonce(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: 999,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidSignature.selector));
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_signatureOverWrongSignatureExpirationTs(
        uint256 bridgedAmount,
        uint256 signatureExpirationTs
    ) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 actualSignatureExpirationTs = uint32(block.timestamp + 2000);
        vm.assume(signatureExpirationTs != actualSignatureExpirationTs);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: actualSignatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidSignature.selector));
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_signatureOverWrongAsset(uint256 bridgedAmount, address wrongAsset)
        public
    {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);
        vm.assume(wrongAsset != address(_mockUsdt));

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: wrongAsset,
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidSignature.selector));
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_signatureOverWrongAmount(uint256 bridgedAmount, uint256 wrongAmount)
        public
    {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);
        vm.assume(wrongAmount != bridgedAmount);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: wrongAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidSignature.selector));
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_reverts_nonceAlreadyConsumed(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);
        uint256 signatureNonce = 1;

        // Manually consume the nonce
        vm.expectEmit(true, true, true, true);
        emit IAcrossBridgeAdapter.NonceConsumed(accountingChainSigner, signatureNonce);
        vm.prank(accountingChainSigner);
        _accountingChainAcrossAdapter.invalidateNonce(accountingChainSigner, signatureNonce);

        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);

        // Sign contents of bridged message with the accounting chain signer
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);

        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SignatureNonceAlreadyConsumed.selector, accountingChainSigner, signatureNonce
            )
        );
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_revert_ifInvalidAcrossPacket(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        bytes memory invalidAcrossPacket = abi.encode(hex"c0DDee");

        vm.prank(address(_mockAcrossSpokePool));
        vm.expectRevert();
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), invalidAcrossPacket
        );

        // Check that the funds are still in the AcrossAdapter
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), bridgedAmount);
    }

    function test_handleV3AcrossMessage_handlesFundsHandlingFailure(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        uint256 signatureNonce = 1;
        uint256 signatureExpirationTs = uint32(block.timestamp + 2000);
        bytes memory signature = _signBridgeData(
            SignBridgeDataParams({
                signerPk: accountingChainSignerPk,
                // Need to use block.chainid since that is what is read in the AcrossAdapter contract
                destinationChainId: block.chainid,
                verifyingContractAddress: address(_accountingChainAcrossAdapter),
                sourceChainId: EARNING_CHAIN_ID,
                signatureNonce: signatureNonce,
                signatureExpirationTs: signatureExpirationTs,
                asset: address(_mockUsdt),
                amount: bridgedAmount
            })
        );

        bytes memory bridgedMessage = abi.encode(hex"c0ffee");
        bytes32 messageId = keccak256(signature);
        AcrossAdapter.AcrossPacket memory acrossPacket = AcrossAdapter.AcrossPacket({
            message: bridgedMessage,
            sourceChainId: EARNING_CHAIN_ID,
            signatureNonce: signatureNonce,
            signatureExpirationTs: signatureExpirationTs,
            signature: signature,
            messageId: messageId
        });

        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.TokenReceptionFailed(EARNING_CHAIN_ID, address(_mockUsdt), bridgedAmount);
        vm.expectEmit(true, true, true, true);
        emit IBridgeAdapter.BridgedFundsProcessingFailed(EARNING_CHAIN_ID, abi.encode(acrossPacket), abi.encode("test"));

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: bridgedAmount});
        vm.mockCallRevert(
            address(_mockAccountingChainGateway),
            abi.encodeCall(IChainGateway.receiveMessage, (0, assets, "")),
            abi.encode("test")
        );
        vm.prank(address(_mockAcrossSpokePool));
        _accountingChainAcrossAdapter.handleV3AcrossMessage(
            address(_mockUsdt), bridgedAmount, address(0), abi.encode(acrossPacket)
        );
    }

    function test_setSigner(address signer, bool whitelistedSigner) public {
        vm.expectEmit(true, true, true, true);
        emit IAcrossBridgeAdapter.SignerUpdated(signer, whitelistedSigner);
        vm.prank(everyRoleAccount);
        _accountingChainAcrossAdapter.setSigner(signer, whitelistedSigner);
    }

    function test_setSigner_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        address signer,
        bool whitelistedSigner
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(_accountingChainAcrossAdapter));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedMsgSender,
                address(_accountingChainAcrossAdapter),
                bytes4(AcrossAdapter.setSigner.selector)
            ),
            abi.encode(false)
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        _accountingChainAcrossAdapter.setSigner(signer, whitelistedSigner);
    }

    function test_replayFundsReceiving(uint256 bridgedAmount) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: bridgedAmount});

        vm.expectCall(
            address(_mockUsdt), abi.encodeCall(IERC20.transfer, (address(_mockTransferHelper), bridgedAmount))
        );
        vm.expectCall(
            address(_mockAccountingChainGateway), abi.encodeCall(IChainGateway.receiveMessage, (0, assets, ""))
        );

        vm.prank(everyRoleAccount);
        _accountingChainAcrossAdapter.replayFundsReceiving(assets);

        // Check the funds have moved from the TransferHelper to the Accounting Chain Gateway
        assertEq(_mockUsdt.balanceOf(address(_accountingChainAcrossAdapter)), 0);
        assertEq(_mockUsdt.balanceOf(address(_mockTransferHelper)), 0);
        assertEq(_mockUsdt.balanceOf(address(_mockAccountingChainGateway)), bridgedAmount);
    }

    function test_replayFundsReceiving_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 bridgedAmount
    ) public {
        bridgedAmount = _boundAssetAmount(address(_mockUsdt), bridgedAmount);
        // Mint the assets to the AcrossAdapter
        _mockUsdt.mint(address(_accountingChainAcrossAdapter), bridgedAmount);

        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: address(_mockUsdt), amount: bridgedAmount});
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

    function _signBridgeData(SignBridgeDataParams memory params) internal pure returns (bytes memory) {
        bytes32 digest = _getSigningPayload(
            params.destinationChainId,
            params.verifyingContractAddress,
            params.sourceChainId,
            params.signatureNonce,
            params.signatureExpirationTs,
            params.asset,
            params.amount
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(params.signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _getSigningPayload(
        uint256 destinationChainId,
        address verifyingContractAddress,
        uint256 sourceChainId,
        uint256 signatureNonce,
        uint256 signatureExpirationTs,
        address asset,
        uint256 amount
    ) internal pure returns (bytes32) {
        bytes32 ACROSS_MESSAGE_TYPEHASH = keccak256(
            "AcrossMessage(uint256 sourceChainId,uint256 signatureNonce,uint256 signatureExpirationTs,address asset,uint256 amount)"
        );

        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 structHash = keccak256(
            abi.encode(ACROSS_MESSAGE_TYPEHASH, sourceChainId, signatureNonce, signatureExpirationTs, asset, amount)
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AcrossAdapter"),
                keccak256("1"),
                destinationChainId,
                verifyingContractAddress
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _buildDepositV3ExpectCallData(DepositV3ExpectCallParams memory p) internal view returns (bytes memory) {
        AcrossAdapter.AcrossPacket memory expectedAcrossPacket = AcrossAdapter.AcrossPacket({
            message: p.message,
            sourceChainId: block.chainid,
            signatureNonce: p.signatureNonce,
            signatureExpirationTs: p.signatureExpirationTs,
            signature: p.signature,
            messageId: p.messageId
        });

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
