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

/// @notice Minimal gateway that records receives and forwards publishes to a bridge adapter.
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

/// @dev Shared fork setup, Pigeon helpers, and helpers for local aDI + Stable Vaults `AdiAdapter` fork tests.
abstract contract AdiAdapterPigeonLocalForkBase is Test {
    uint256 internal constant ETH_CHAIN_ID = 1;
    uint256 internal constant ARB_CHAIN_ID = 42161;
    uint256 internal constant DEFAULT_GAS_LIMIT = 200_000;

    string internal constant DEFAULT_ETH_FORK_RPC = "http://127.0.0.1:8545";
    string internal constant DEFAULT_ARB_FORK_RPC = "http://127.0.0.1:8546";

    address internal constant DEFAULT_STABLE_VAULTS_OWNER = 0xfB65C68526969DA4AA3cEDF30b1C53846116D5a2;

    address internal constant DEFAULT_ETH_CCC = 0x33E3B9D276f58A873e9Acc9f25A8a46F5b66F259;
    address internal constant DEFAULT_ARB_CCC = 0x98cF75814a129845EA7d69dbD0B6923A6Dac0c6b;

    address internal constant DEFAULT_ETH_ARB_ADAPTER = 0xC9B2A285B62c0eD494C3C23FAc7C169EaE740C59;

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
    address internal _stableVaultsOwner;
    address internal _ethCcc;
    address internal _arbCcc;
    address internal _ethArbAdapter;

    /// @dev Optional deployment addresses from `adi-deploy` JSON (exported by `run-adi-pigeon-fork-test.sh`).
    address internal _ethCcipAdapter;
    address internal _ethLzAdapter;
    address internal _ethHlAdapter;
    address internal _arbCcipAdapter;
    address internal _arbLzAdapter;
    address internal _arbHlAdapter;

    modifier onlyForkTest() {
        vm.skip(!vm.envOr("FORK_TEST", false), "Set FORK_TEST=true to run local aDI fork integration tests");
        _;
    }

    function setUp() public virtual {
        if (!vm.envOr("FORK_TEST", false)) {
            return;
        }

        _ethFork = vm.createSelectFork(vm.envOr("ETH_FORK_RPC", DEFAULT_ETH_FORK_RPC));
        _arbFork = vm.createSelectFork(vm.envOr("ARB_FORK_RPC", DEFAULT_ARB_FORK_RPC));
        _loadForkDeploymentConfig();

        vm.selectFork(_ethFork);
        (_ethGateway, _ethAdiAdapter) = _deployLocalAdapter(_ethCcc);

        vm.selectFork(_arbFork);
        (_arbGateway, _arbAdiAdapter) = _deployLocalAdapter(_arbCcc);

        _deployPigeonHelpers();
        _configureAdaptersAndAdiPermissions();
    }

    function _deployLocalAdapter(address crossChainController)
        internal
        returns (RecordingGateway gateway, AdiAdapter adapter)
    {
        MockAccessManager accessManager = new MockAccessManager(_stableVaultsOwner);
        MockTransferHelper transferHelper = new MockTransferHelper();
        gateway = new RecordingGateway();
        adapter =
            new AdiAdapter(address(accessManager), address(gateway), crossChainController, address(transferHelper));
    }

    function _loadForkDeploymentConfig() internal virtual {
        _stableVaultsOwner = vm.envOr("STABLE_VAULTS_OWNER", DEFAULT_STABLE_VAULTS_OWNER);
        _ethCcc = vm.envOr("ETH_CCC", DEFAULT_ETH_CCC);
        _arbCcc = vm.envOr("ARB_CCC", DEFAULT_ARB_CCC);
        _ethArbAdapter = vm.envOr("ETH_ARB_ADAPTER", DEFAULT_ETH_ARB_ADAPTER);

        _ethCcipAdapter = vm.envOr("ETH_CCIP_ADAPTER", address(0));
        _ethLzAdapter = vm.envOr("ETH_LZ_ADAPTER", address(0));
        _ethHlAdapter = vm.envOr("ETH_HL_ADAPTER", address(0));
        _arbCcipAdapter = vm.envOr("ARB_CCIP_ADAPTER", address(0));
        _arbLzAdapter = vm.envOr("ARB_LZ_ADAPTER", address(0));
        _arbHlAdapter = vm.envOr("ARB_HL_ADAPTER", address(0));
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
        _approveAdiAdapter(_ethCcc, address(_ethAdiAdapter));
        vm.deal(_ethCcc, 20 ether);

        vm.selectFork(_arbFork);
        _arbAdiAdapter.setDestinationChainAdapter(ETH_CHAIN_ID, address(_ethAdiAdapter));
        _approveAdiAdapter(_arbCcc, address(_arbAdiAdapter));
        vm.deal(_arbCcc, 20 ether);
    }

    function _approveAdiAdapter(address crossChainController, address adiAdapter) internal {
        address[] memory senders = new address[](1);
        senders[0] = adiAdapter;

        vm.startPrank(_stableVaultsOwner);
        IAdiControllerAdmin(crossChainController).approveSenders(senders);
        IAdiControllerAdmin(crossChainController).updateGuardian(adiAdapter);
        vm.stopPrank();

        assertTrue(IAdiControllerAdmin(crossChainController).isSenderApproved(adiAdapter), "adapter not approved");
        assertEq(IAdiControllerAdmin(crossChainController).guardian(), adiAdapter, "adapter not guardian");
    }

    function _setGuardian(address crossChainController, address guardian) internal {
        vm.prank(_stableVaultsOwner);
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

    function _prepareRetryEnvelopeFees(AdiAdapter adapter, IAdiCrossChainForwarder.Envelope memory envelope)
        internal
        returns (uint256 nativeFee)
    {
        uint256 quoteBandwidth = IAdiCrossChainForwarder(adapter.getCrossChainController())
            .getOptimalBandwidthByChain(envelope.destinationChainId);
        IAdiCrossChainForwarder.Fee[] memory fees;
        uint256 successfulQuotes;
        (nativeFee, fees, successfulQuotes) = adapter.quoteRetryEnvelope(envelope, DEFAULT_GAS_LIMIT, quoteBandwidth);
        assertGt(successfulQuotes, 0, "no successful retry envelope quotes");

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

    function _envelopeFromFirstSuccessfulForward(Vm.Log[] memory logs)
        internal
        pure
        returns (IAdiCrossChainForwarder.Envelope memory envelope)
    {
        bytes memory encodedTransaction = _firstSuccessfulEncodedTransaction(logs);
        IAdiCrossChainForwarder.Transaction memory transaction =
            abi.decode(encodedTransaction, (IAdiCrossChainForwarder.Transaction));
        envelope = abi.decode(transaction.encodedEnvelope, (IAdiCrossChainForwarder.Envelope));
    }

    function _singleAddress(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }
}
