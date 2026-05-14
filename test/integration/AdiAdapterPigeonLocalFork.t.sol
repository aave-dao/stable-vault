// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {IAdiCrossChainForwarder} from "src/interfaces/IAdiCrossChainForwarder.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {Constants} from "src/types/Constants.sol";

import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

import {AdiHelper} from "pigeon/src/adi/AdiHelper.sol";
import {ArbitrumNativeHelper} from "pigeon/src/arbitrum/ArbitrumNativeHelper.sol";
import {CcipHelper} from "pigeon/src/ccip/CcipHelper.sol";
import {HyperlaneHelper} from "pigeon/src/hyperlane/HyperlaneHelper.sol";
import {LayerZeroV2Helper} from "pigeon/src/layerzero-v2/LayerZeroV2Helper.sol";

interface IAdiControllerAdmin {
    function approveSenders(address[] memory senders) external;
    function isSenderApproved(address sender) external view returns (bool);
    function updateGuardian(address newGuardian) external;
    function guardian() external view returns (address);
}

contract RecordingGateway is IChainGateway {
    uint256 public receiveCount;
    uint256 public lastSourceChainId;
    address public lastAsset;
    uint256 public lastAmount;
    bytes public lastData;

    function publishDataMessage(
        uint256 destinationChainId,
        address bridgeAdapter,
        address feePayer,
        uint256 gasLimit,
        bytes memory data
    ) external payable {
        IBridgeAdapter(bridgeAdapter).publishMessageToChainWithFeePayer{value: msg.value}(
            destinationChainId, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, data, feePayer, gasLimit, ""
        );
    }

    function getIouTokenManager() external pure returns (address) {
        return address(0);
    }

    function addBridgeAdapter(address, uint256, address) external {}

    function removeBridgeAdapter(address, uint256, address) external {}

    function receiveMessage(uint256 sourceChainId, address asset, uint256 amount, bytes memory data) external {
        receiveCount++;
        lastSourceChainId = sourceChainId;
        lastAsset = asset;
        lastAmount = amount;
        lastData = data;
    }

    function sendBridgeIouTokenMessageWithFeePayer(uint256, address, uint256, address, address, uint256, bytes calldata)
        external
        payable {}
}

contract AdiAdapterPigeonLocalForkTest is Test {
    uint256 internal constant ETH_CHAIN_ID = 1;
    uint256 internal constant ARB_CHAIN_ID = 42161;
    uint256 internal constant DEFAULT_GAS_LIMIT = 200_000;

    string internal constant DEFAULT_ETH_FORK_RPC = "http://127.0.0.1:8545";
    string internal constant DEFAULT_ARB_FORK_RPC = "http://127.0.0.1:8546";

    address internal constant STABLE_VAULTS_OWNER = 0xfB65C68526969DA4AA3cEDF30b1C53846116D5a2;

    address internal constant ETH_CCC = 0x33E3B9D276f58A873e9Acc9f25A8a46F5b66F259;
    address internal constant ARB_CCC = 0x98cF75814a129845EA7d69dbD0B6923A6Dac0c6b;

    address internal constant ETH_ARB_ADAPTER = 0xC9B2A285B62c0eD494C3C23FAc7C169EaE740C59;

    address internal constant ARB_INBOX = 0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f;
    address internal constant ARB_BRIDGE = 0x8315177aB297bA92A06054cE80a67Ed4DBd7ed3a;
    address internal constant ETH_CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    uint64 internal constant ETH_CCIP_CHAIN_SELECTOR = 5009297550715157269;
    address internal constant LZ_ENDPOINT_V2 = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant ETH_HL_MAILBOX = 0xc005dc82818d67AF737725bD4bf75435d065D239;
    address internal constant ARB_HL_MAILBOX = 0x979Ca5202784112f4738403dBec5D0F3B9daabB9;

    bytes32 internal constant TRANSACTION_FORWARDING_ATTEMPTED_SELECTOR =
        keccak256("TransactionForwardingAttempted(bytes32,bytes32,bytes,uint256,address,address,bool,bytes)");

    uint256 internal _ethFork;
    uint256 internal _arbFork;

    AdiHelper internal _adiHelper;

    RecordingGateway internal _ethGateway;
    RecordingGateway internal _arbGateway;
    AdiAdapter internal _ethAdiAdapter;
    AdiAdapter internal _arbAdiAdapter;

    modifier onlyForkTest() {
        vm.skip(!vm.envOr("FORK_TEST", false), "Set FORK_TEST=true to run local aDI fork integration tests");
        _;
    }

    function setUp() public {
        if (!vm.envOr("FORK_TEST", false)) {
            return;
        }

        _ethFork = vm.createSelectFork(vm.envOr("ETH_FORK_RPC", DEFAULT_ETH_FORK_RPC));
        _arbFork = vm.createSelectFork(vm.envOr("ARB_FORK_RPC", DEFAULT_ARB_FORK_RPC));

        vm.selectFork(_ethFork);
        (_ethGateway, _ethAdiAdapter) = _deployLocalAdapter(ETH_CCC);

        vm.selectFork(_arbFork);
        (_arbGateway, _arbAdiAdapter) = _deployLocalAdapter(ARB_CCC);

        _deployPigeonHelpers();
        _configureAdaptersAndAdiPermissions();
    }

    function test_ethToArb_pigeonFork_deliversViaLocalAdi() public onlyForkTest {
        bytes memory message = abi.encode("hello-arb");

        vm.selectFork(_ethFork);
        uint256 nativeFee = _prepareForwardFees(_ethAdiAdapter, ARB_CHAIN_ID, message);

        vm.recordLogs();
        _ethGateway.publishDataMessage{value: nativeFee}(
            ARB_CHAIN_ID, address(_ethAdiAdapter), address(this), DEFAULT_GAS_LIMIT, message
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_adiHelper.countSuccessfulForwards(logs), 1, "ETH->ARB should forward through one adapter");

        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: ETH_CCC, logs: logs
            })
        );

        vm.selectFork(_arbFork);
        assertEq(_arbGateway.receiveCount(), 1, "ARB gateway did not receive");
        assertEq(_arbGateway.lastSourceChainId(), ETH_CHAIN_ID, "unexpected source chain");
        assertEq(_arbGateway.lastAsset(), Constants.ASSET_FOR_DATA_ONLY_BRIDGE, "unexpected asset");
        assertEq(_arbGateway.lastAmount(), 0, "unexpected amount");
        assertEq(abi.decode(_arbGateway.lastData(), (string)), "hello-arb", "unexpected message");
    }

    function test_arbToEth_pigeonFork_deliversViaTwoOfThree() public onlyForkTest {
        bytes memory message = abi.encode("hello-eth");

        vm.selectFork(_arbFork);
        uint256 nativeFee = _prepareForwardFees(_arbAdiAdapter, ETH_CHAIN_ID, message);

        vm.recordLogs();
        _arbGateway.publishDataMessage{value: nativeFee}(
            ETH_CHAIN_ID, address(_arbAdiAdapter), address(this), DEFAULT_GAS_LIMIT, message
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGe(_adiHelper.countSuccessfulForwards(logs), 2, "ARB->ETH should meet forwarding threshold");

        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: ETH_CCIP_ROUTER,
                dstCcipChainSelector: ETH_CCIP_CHAIN_SELECTOR,
                srcCcipOnRamp: address(0),
                dstLzEndpoint: LZ_ENDPOINT_V2,
                srcHlMailbox: ARB_HL_MAILBOX,
                dstHlMailbox: ETH_HL_MAILBOX,
                logs: logs
            })
        );

        vm.selectFork(_ethFork);
        assertEq(_ethGateway.receiveCount(), 1, "ETH gateway did not receive");
        assertEq(_ethGateway.lastSourceChainId(), ARB_CHAIN_ID, "unexpected source chain");
        assertEq(_ethGateway.lastAsset(), Constants.ASSET_FOR_DATA_ONLY_BRIDGE, "unexpected asset");
        assertEq(_ethGateway.lastAmount(), 0, "unexpected amount");
        assertEq(abi.decode(_ethGateway.lastData(), (string)), "hello-eth", "unexpected message");
    }

    function test_retryTransaction_pigeonFork_deliversViaLocalAdiGuardian() public onlyForkTest {
        bytes memory message = abi.encode("retry-hello-arb");
        address[] memory bridgeAdaptersToRetry = _singleAddress(ETH_ARB_ADAPTER);

        vm.selectFork(_ethFork);
        uint256 forwardNativeFee = _prepareForwardFees(_ethAdiAdapter, ARB_CHAIN_ID, message);

        vm.recordLogs();
        _ethGateway.publishDataMessage{value: forwardNativeFee}(
            ARB_CHAIN_ID, address(_ethAdiAdapter), address(this), DEFAULT_GAS_LIMIT, message
        );
        Vm.Log[] memory forwardLogs = vm.getRecordedLogs();
        bytes memory encodedTransaction = _firstSuccessfulEncodedTransaction(forwardLogs);

        vm.selectFork(_arbFork);
        assertEq(_arbGateway.receiveCount(), 0, "original transaction should not be relayed");

        vm.selectFork(_ethFork);
        _setGuardian(ETH_CCC, STABLE_VAULTS_OWNER);
        uint256 retryNativeFee = _prepareRetryFees(_ethAdiAdapter, encodedTransaction, bridgeAdaptersToRetry);

        vm.expectRevert();
        _ethAdiAdapter.retryTransaction{value: retryNativeFee}(
            encodedTransaction, DEFAULT_GAS_LIMIT, bridgeAdaptersToRetry
        );

        _setGuardian(ETH_CCC, address(_ethAdiAdapter));
        retryNativeFee = _prepareRetryFees(_ethAdiAdapter, encodedTransaction, bridgeAdaptersToRetry);

        vm.recordLogs();
        _ethAdiAdapter.retryTransaction{value: retryNativeFee}(
            encodedTransaction, DEFAULT_GAS_LIMIT, bridgeAdaptersToRetry
        );
        Vm.Log[] memory retryLogs = vm.getRecordedLogs();

        assertEq(_adiHelper.countSuccessfulForwards(retryLogs), 1, "retry should forward through one adapter");

        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: ETH_CCC, logs: retryLogs
            })
        );

        vm.selectFork(_arbFork);
        assertEq(_arbGateway.receiveCount(), 1, "ARB gateway did not receive retry");
        assertEq(_arbGateway.lastSourceChainId(), ETH_CHAIN_ID, "unexpected source chain");
        assertEq(abi.decode(_arbGateway.lastData(), (string)), "retry-hello-arb", "unexpected retry message");
    }

    function _deployLocalAdapter(address crossChainController)
        internal
        returns (RecordingGateway gateway, AdiAdapter adapter)
    {
        MockAccessManager accessManager = new MockAccessManager(STABLE_VAULTS_OWNER);
        MockTransferHelper transferHelper = new MockTransferHelper();
        gateway = new RecordingGateway();
        adapter =
            new AdiAdapter(address(accessManager), address(gateway), crossChainController, address(transferHelper));
    }

    function _deployPigeonHelpers() internal {
        CcipHelper ccipHelper = new CcipHelper();
        LayerZeroV2Helper lzHelper = new LayerZeroV2Helper();
        HyperlaneHelper hlHelper = new HyperlaneHelper();
        ArbitrumNativeHelper arbHelper = new ArbitrumNativeHelper();
        _adiHelper = new AdiHelper(ccipHelper, lzHelper, hlHelper, arbHelper);
    }

    function _configureAdaptersAndAdiPermissions() internal {
        vm.selectFork(_ethFork);
        _ethAdiAdapter.setDestinationChainAdapter(ARB_CHAIN_ID, address(_arbAdiAdapter));
        _approveAdiAdapter(ETH_CCC, address(_ethAdiAdapter));
        vm.deal(ETH_CCC, 20 ether);

        vm.selectFork(_arbFork);
        _arbAdiAdapter.setDestinationChainAdapter(ETH_CHAIN_ID, address(_ethAdiAdapter));
        _approveAdiAdapter(ARB_CCC, address(_arbAdiAdapter));
        vm.deal(ARB_CCC, 20 ether);
    }

    function _approveAdiAdapter(address crossChainController, address adiAdapter) internal {
        address[] memory senders = new address[](1);
        senders[0] = adiAdapter;

        vm.startPrank(STABLE_VAULTS_OWNER);
        IAdiControllerAdmin(crossChainController).approveSenders(senders);
        IAdiControllerAdmin(crossChainController).updateGuardian(adiAdapter);
        vm.stopPrank();

        assertTrue(IAdiControllerAdmin(crossChainController).isSenderApproved(adiAdapter), "adapter not approved");
        assertEq(IAdiControllerAdmin(crossChainController).guardian(), adiAdapter, "adapter not guardian");
    }

    function _setGuardian(address crossChainController, address guardian) internal {
        vm.prank(STABLE_VAULTS_OWNER);
        IAdiControllerAdmin(crossChainController).updateGuardian(guardian);
        assertEq(IAdiControllerAdmin(crossChainController).guardian(), guardian, "unexpected guardian");
    }

    function _prepareForwardFees(AdiAdapter adapter, uint256 destinationChainId, bytes memory message)
        internal
        returns (uint256 nativeFee)
    {
        IAdiCrossChainForwarder.Fee[] memory fees;
        uint256 successfulQuotes;
        (nativeFee, fees, successfulQuotes) =
            adapter.quoteMessageToChain(destinationChainId, message, DEFAULT_GAS_LIMIT);
        assertGt(successfulQuotes, 0, "no successful aDI quotes");

        for (uint256 i = 0; i < fees.length; i++) {
            if (fees[i].amount == 0) {
                continue;
            }
            deal(fees[i].token, address(this), fees[i].amount);
            IERC20(fees[i].token).approve(address(adapter), fees[i].amount);
        }

        if (nativeFee > 0) {
            vm.deal(address(this), nativeFee);
        }
    }

    function _prepareRetryFees(
        AdiAdapter adapter,
        bytes memory encodedTransaction,
        address[] memory bridgeAdaptersToRetry
    ) internal returns (uint256 nativeFee) {
        IAdiCrossChainForwarder.Fee[] memory fees;
        uint256 successfulQuotes;
        (nativeFee, fees, successfulQuotes) =
            adapter.quoteRetryTransaction(encodedTransaction, DEFAULT_GAS_LIMIT, bridgeAdaptersToRetry);
        assertGt(successfulQuotes, 0, "no successful retry quotes");

        for (uint256 i = 0; i < fees.length; i++) {
            if (fees[i].amount == 0) {
                continue;
            }
            deal(fees[i].token, address(this), fees[i].amount);
            IERC20(fees[i].token).approve(address(adapter), fees[i].amount);
        }

        if (nativeFee > 0) {
            vm.deal(address(this), nativeFee);
        }
    }

    function _firstSuccessfulEncodedTransaction(Vm.Log[] memory logs) internal pure returns (bytes memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length < 4) {
                continue;
            }
            if (logs[i].topics[0] != TRANSACTION_FORWARDING_ATTEMPTED_SELECTOR) {
                continue;
            }
            if (logs[i].topics[3] != bytes32(uint256(1))) {
                continue;
            }

            (bytes32 transactionId, bytes memory encodedTransaction,,,) =
                abi.decode(logs[i].data, (bytes32, bytes, uint256, address, bytes));
            require(transactionId != bytes32(0), "INVALID_TRANSACTION_ID");
            return encodedTransaction;
        }

        revert("NO_SUCCESSFUL_TRANSACTION");
    }

    function _singleAddress(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }
}
