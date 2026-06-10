// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {ICrossChainReceiver} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainReceiver.sol";
import {Envelope, Transaction} from "aave-delivery-infrastructure/contracts/libs/EncodingUtils.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {Constants} from "src/types/Constants.sol";

import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

import {AdiHandoffSimulator} from "./AdiHandoffSimulator.sol";

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

/// @dev Minimal getters for reading each AMB endpoint from its deployed a.DI bridge adapter on-chain, so tests
/// follow whatever infrastructure the deployment wired instead of hardcoding canonical AMB addresses.
interface ICcipAdapterLike {
    function CCIP_ROUTER() external view returns (address);
}

interface ILzAdapterLike {
    function LZ_ENDPOINT() external view returns (address);
}

interface IHlAdapterLike {
    function HL_MAIL_BOX() external view returns (address);
}

interface IArbAdapterLike {
    function INBOX() external view returns (address);
}

interface IArbInboxLike {
    function bridge() external view returns (address);
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
        IBridgeAdapter(bridgeAdapter).publishDataOnlyMessage{value: msg.value}(
            destinationChainId, data, feePayer, gasLimit, ""
        );
    }

    function getIouTokenManager() external pure returns (address) {
        return address(0);
    }

    function addFundsBridgeAdapter(address, uint256, address) external {}

    function removeFundsBridgeAdapter(address, uint256, address) external {}

    function addDataOnlyBridgeAdapter(uint256, address) external {}

    function initiateDataOnlyBridgeAdapterRemoval(uint256, address) external returns (bytes32 removalId) {}

    function finalizeDataOnlyBridgeAdapterRemoval(uint256, address, bytes32) external {}

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
abstract contract AdiAdapterPigeonLocalForkBase is Test, AdiHandoffSimulator {
    uint256 internal constant ETH_CHAIN_ID = 1;
    uint256 internal constant ARB_CHAIN_ID = 42161;
    uint256 internal constant DEFAULT_GAS_LIMIT = 200_000;

    string internal constant DEFAULT_ETH_FORK_RPC = "http://127.0.0.1:8545";
    string internal constant DEFAULT_ARB_FORK_RPC = "http://127.0.0.1:8546";

    // CCIP chain selectors are CCIP protocol constants (not surfaced by the deployment), so they stay hardcoded.
    uint64 internal constant ETH_CCIP_CHAIN_SELECTOR = 5009297550715157269;
    uint64 internal constant ARB_CCIP_CHAIN_SELECTOR = 4949039107694359620;

    // AMB endpoints, resolved on-chain from the deployed a.DI adapters in `_loadAmbEndpointsFromAdapters`.
    address internal ARB_INBOX;
    address internal ARB_BRIDGE;
    address internal ETH_CCIP_ROUTER;
    address internal ARB_CCIP_ROUTER;
    address internal LZ_ENDPOINT_V2;
    address internal ETH_HL_MAILBOX;
    address internal ARB_HL_MAILBOX;

    bytes32 internal constant TRANSACTION_FORWARDING_ATTEMPTED_SELECTOR =
        keccak256("TransactionForwardingAttempted(bytes32,bytes32,bytes,uint256,address,address,bool,bytes)");

    uint256 internal _ethFork;
    uint256 internal _arbFork;

    AdiHelper internal _adiHelper;

    RecordingGateway internal _ethGateway;
    RecordingGateway internal _arbGateway;
    AdiAdapter internal _ethAdiAdapter;
    AdiAdapter internal _arbAdiAdapter;
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
        _loadAmbEndpointsFromAdapters();

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
        MockAccessManager accessManager = new MockAccessManager(_cccOwnerOf(crossChainController));
        MockTransferHelper transferHelper = new MockTransferHelper();
        gateway = new RecordingGateway();
        adapter =
            new AdiAdapter(address(accessManager), address(gateway), crossChainController, address(transferHelper));
    }

    /// @dev a.DI CrossChainController + bridge-adapter addresses come from env, exported by
    /// run-adi-pigeon-fork-test.sh from the adi-deploy deployment JSONs. They are required (no hardcoded fallback) so
    /// the tests can never silently run against a stale baked-in address.
    function _loadForkDeploymentConfig() internal virtual {
        _ethCcc = _requireEnvAddress("ETH_CCC");
        _arbCcc = _requireEnvAddress("ARB_CCC");
        _ethArbAdapter = _requireEnvAddress("ETH_ARB_ADAPTER");

        _ethCcipAdapter = _requireEnvAddress("ETH_CCIP_ADAPTER");
        _ethLzAdapter = _requireEnvAddress("ETH_LZ_ADAPTER");
        _ethHlAdapter = _requireEnvAddress("ETH_HL_ADAPTER");
        _arbCcipAdapter = _requireEnvAddress("ARB_CCIP_ADAPTER");
        _arbLzAdapter = _requireEnvAddress("ARB_LZ_ADAPTER");
        _arbHlAdapter = _requireEnvAddress("ARB_HL_ADAPTER");
    }

    function _requireEnvAddress(string memory key) private view returns (address value) {
        value = vm.envOr(key, address(0));
        require(value != address(0), string.concat(key, " not set; run via run-adi-pigeon-fork-test.sh"));
    }

    /// @dev Resolve each AMB endpoint from its deployed a.DI adapter, so the relay targets exactly the infrastructure
    /// the deployment wired (and the Arbitrum bridge is read straight off the inbox).
    function _loadAmbEndpointsFromAdapters() internal {
        vm.selectFork(_ethFork);
        ETH_CCIP_ROUTER = ICcipAdapterLike(_ethCcipAdapter).CCIP_ROUTER();
        LZ_ENDPOINT_V2 = ILzAdapterLike(_ethLzAdapter).LZ_ENDPOINT();
        ETH_HL_MAILBOX = IHlAdapterLike(_ethHlAdapter).HL_MAIL_BOX();
        ARB_INBOX = IArbAdapterLike(_ethArbAdapter).INBOX();
        ARB_BRIDGE = IArbInboxLike(ARB_INBOX).bridge();

        vm.selectFork(_arbFork);
        ARB_CCIP_ROUTER = ICcipAdapterLike(_arbCcipAdapter).CCIP_ROUTER();
        ARB_HL_MAILBOX = IHlAdapterLike(_arbHlAdapter).HL_MAIL_BOX();
    }

    function _deployPigeonHelpers() internal {
        CcipHelper ccipHelper = new CcipHelper();
        LayerZeroV2Helper lzHelper = new LayerZeroV2Helper();
        HyperlaneHelper hlHelper = new HyperlaneHelper();
        ArbitrumNativeHelper arbHelper = new ArbitrumNativeHelper();
        _adiHelper = new AdiHelper(ccipHelper, lzHelper, hlHelper, arbHelper);
    }

    /// @dev Relay a single ARB->ETH a.DI bridge leg into the Ethereum CCC (0 = CCIP, 1 = LayerZero, 2 = Hyperlane), so
    /// quorum-staged tests can deliver confirmations one at a time and assert behavior against the receiver quorum.
    function _relayArbToEthSingleAmb(Vm.Log[] memory logs, uint256 ambIndex) internal {
        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: ambIndex == 0 ? ETH_CCIP_ROUTER : address(0),
                dstCcipChainSelector: ambIndex == 0 ? ETH_CCIP_CHAIN_SELECTOR : uint64(0),
                srcCcipOnRamp: address(0),
                dstLzEndpoint: ambIndex == 1 ? LZ_ENDPOINT_V2 : address(0),
                srcHlMailbox: ambIndex == 2 ? ARB_HL_MAILBOX : address(0),
                dstHlMailbox: ambIndex == 2 ? ETH_HL_MAILBOX : address(0),
                logs: logs
            })
        );
    }

    /// @dev Required confirmations for ARB->ETH messages on the Ethereum receiver, read on-chain so quorum-staged tests
    /// track whatever the deployment configured (e.g. 2-of-3 or 3-of-3). Selects the Ethereum fork to read the CCC.
    function _arbToEthQuorum() internal returns (uint256) {
        vm.selectFork(_ethFork);
        return ICrossChainReceiver(_ethCcc).getConfigurationByChain(ARB_CHAIN_ID).requiredConfirmation;
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

        vm.startPrank(_cccOwnerOf(crossChainController));
        IAdiControllerAdmin(crossChainController).approveSenders(senders);
        IAdiControllerAdmin(crossChainController).updateGuardian(adiAdapter);
        vm.stopPrank();

        assertTrue(IAdiControllerAdmin(crossChainController).isSenderApproved(adiAdapter), "adapter not approved");
        assertEq(IAdiControllerAdmin(crossChainController).guardian(), adiAdapter, "adapter not guardian");
    }

    function _setGuardian(address crossChainController, address guardian) internal {
        vm.prank(_cccOwnerOf(crossChainController));
        IAdiControllerAdmin(crossChainController).updateGuardian(guardian);
        assertEq(IAdiControllerAdmin(crossChainController).guardian(), guardian, "unexpected guardian");
    }

    /// @dev Current owner of `target` (CrossChainController or bridge adapter), read on the active fork. Replaces a
    /// hardcoded/env owner so the tests always prank whoever actually controls the deployed contract.
    function _cccOwnerOf(address target) internal view returns (address) {
        return Ownable(target).owner();
    }

    function _prepareForwardFees(AdiAdapter adapter, uint256 destinationChainId, bytes memory message)
        internal
        returns (uint256 nativeFee)
    {
        ICrossChainForwarder.Fee[] memory fees;
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
        ICrossChainForwarder.Fee[] memory fees;
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

    function _prepareRetryEnvelopeFees(AdiAdapter adapter, Envelope memory envelope)
        internal
        returns (uint256 nativeFee)
    {
        uint256 quoteBandwidth = ICrossChainForwarder(adapter.getCrossChainController())
            .getOptimalBandwidthByChain(envelope.destinationChainId);
        ICrossChainForwarder.Fee[] memory fees;
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
        returns (Envelope memory envelope)
    {
        bytes memory encodedTransaction = _firstSuccessfulEncodedTransaction(logs);
        Transaction memory transaction = abi.decode(encodedTransaction, (Transaction));
        envelope = abi.decode(transaction.encodedEnvelope, (Envelope));
    }

    function _singleAddress(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }
}
