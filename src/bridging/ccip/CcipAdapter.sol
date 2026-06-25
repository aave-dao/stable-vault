// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {BaseBridgeAdapter} from "src/bridging/BaseBridgeAdapter.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {RescuableNative} from "src/misc/RescuableNative.sol";
import {RescuableToken} from "src/misc/RescuableToken.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title CcipAdapter
/// @author Aave Labs
/// @notice Adapter for sending and receiving messages via Chainlink CCIP.
/// @dev This adapter will not ingest user-specific tokens and data, therefore the adapter does not support
/// returning tokens to the original sender on the source chain (original sender will be the source chain CCIP adapter).
/// @dev This adapter does not implement a defensive receiver pattern because it is assumed that message ingestion will
/// not fail downstream due to issues other than OOG, deposits into the Allocator being disabled, or a transient
/// StaleChainBalance revert (the latter clears once the balance oracle refreshes, after which the message is
/// re-executed via manual execution through the CCIP offramp).
/// @dev If a revert occurs during the processing of a message, the message will need to be retried (through
/// manual execution through the CCIP offramp).
/// @dev The adapter will revert if the source chain sender is not recognized, and the message will never need to be
/// retried (through manual execution through the CCIP offramp).
contract CcipAdapter is
    BaseBridgeAdapter,
    ReentrancyGuardTransient,
    RescuableNative,
    RescuableToken,
    ICcipBridgeAdapter,
    IAny2EVMMessageReceiver,
    IERC165
{
    using SafeERC20 for IERC20;

    /// @notice CCIP-specific fee parameters decoded by `CcipAdapter` when publishing a message.
    /// @param feeToken Token to pay the bridge fee in.
    /// @param nativeFeeRefundThreshold Minimum native-fee surplus over the CCIP-quote estimate that triggers a refund
    /// to `feePayer`
    struct CcipFeeParams {
        address feeToken;
        uint256 nativeFeeRefundThreshold;
    }

    /// @dev CCIP's `EVM2AnyMessage.feeToken` uses `address(0)` for native. This adapter translates our own native
    /// currency constant convention to CCIP's convention.
    address internal constant CCIP_NATIVE_FEE_TOKEN = address(0);

    /// @dev Gas added on top of data-only payload execution so CCIP can execute this adapter around the gateway call.
    /// Gas tests measured about 15.3k gas for this exact-gas path; 30k keeps close to a 2x margin.
    uint256 internal constant DATA_ONLY_RECEIVE_GAS_OVERHEAD = 30_000;

    address internal immutable CCIP_ROUTER;
    address internal immutable ASSET_REGISTRY;

    mapping(uint256 chainId => uint64 ccipChainSelector) internal _chainSelectorOf;
    mapping(uint64 ccipChainSelector => uint256 chainId) internal _chainIdOf;

    modifier onlyRouter() {
        require(msg.sender == CCIP_ROUTER, OnlyBridgeRouter());
        _;
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param gateway Address of the Gateway contract.
    /// @param ccipRouter Address of the Chainlink CCIP router.
    /// @param transferHelper Address of the TransferHelper contract.
    /// @param assetRegistry Address of the AssetRegistry contract.
    constructor(
        address accessManager,
        address gateway,
        address ccipRouter,
        address transferHelper,
        address assetRegistry
    ) BaseBridgeAdapter(accessManager, gateway, transferHelper) {
        require(ccipRouter != address(0), Errors.ZeroAddress());
        require(assetRegistry != address(0), Errors.ZeroAddress());
        CCIP_ROUTER = ccipRouter;
        ASSET_REGISTRY = assetRegistry;
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getRouter() external view override returns (address) {
        return address(CCIP_ROUTER);
    }

    /// @inheritdoc IBridgeAdapter
    function getDataOnlyReceiveGasOverhead()
        public
        pure
        override(BaseBridgeAdapter, IBridgeAdapter)
        returns (uint256 dataOnlyReceiveGasOverhead)
    {
        return DATA_ONLY_RECEIVE_GAS_OVERHEAD;
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getChainSelector(uint256 chainId) external view override returns (uint64) {
        return _chainSelectorOf[chainId];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getChainId(uint64 ccipChainSelector) external view override returns (uint256) {
        return _chainIdOf[ccipChainSelector];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external override restricted {
        uint64 previousSelector = _chainSelectorOf[chainId];
        if (previousSelector != 0 && previousSelector != ccipChainSelector) {
            delete _chainIdOf[previousSelector];
        }
        uint256 previousChainId = _chainIdOf[ccipChainSelector];
        if (previousChainId != 0 && previousChainId != chainId) {
            delete _chainSelectorOf[previousChainId];
        }
        _chainSelectorOf[chainId] = ccipChainSelector;
        _chainIdOf[ccipChainSelector] = chainId;
        emit ChainSelectorSet(chainId, ccipChainSelector);
    }

    /// @inheritdoc IBridgeAdapter
    function publishDataOnlyMessage(
        uint256 destinationChainId,
        bytes memory messageData,
        address feePayer,
        uint256 payloadExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);
        // Add this adapter's receive overhead to the gateway payload execution gas requested upstream.
        uint256 receiverExecutionGasLimit = _withReceiverOverhead(payloadExecutionGasLimit);
        _publishCcipMessage(
            destinationChainId,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            tokenAmounts,
            messageData,
            feePayer,
            receiverExecutionGasLimit,
            bridgeAdapterData
        );
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageWithFunds(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory messageData,
        address feePayer,
        uint256 receiverExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        require(asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0, Errors.InvalidParameter());
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: amount});
        _publishCcipMessage(
            destinationChainId,
            asset,
            amount,
            tokenAmounts,
            messageData,
            feePayer,
            receiverExecutionGasLimit,
            bridgeAdapterData
        );
    }

    function _publishCcipMessage(
        uint256 destinationChainId,
        address assetToBridge,
        uint256 amountToBridge,
        Client.EVMTokenAmount[] memory tokenAmounts,
        bytes memory messageData,
        address feePayer,
        uint256 receiverExecutionGasLimit,
        bytes memory bridgeAdapterData
    ) internal {
        CcipFeeParams memory ccipFeeParams = abi.decode(bridgeAdapterData, (CcipFeeParams));

        address destinationChainAdapter = _destinationChainAdapterOf[destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationChainAdapter),
            data: messageData,
            tokenAmounts: tokenAmounts,
            feeToken: ccipFeeParams.feeToken == Constants.NATIVE_CURRENCY
                ? CCIP_NATIVE_FEE_TOKEN
                : ccipFeeParams.feeToken,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: receiverExecutionGasLimit, allowOutOfOrderExecution: true})
            )
        });

        uint64 chainSelector = _chainSelectorOf[destinationChainId];
        uint256 estimatedFeeAmount = IRouterClient(CCIP_ROUTER).getFee(chainSelector, ccipMessage);

        if (ccipFeeParams.feeToken == Constants.NATIVE_CURRENCY) {
            require(msg.value >= estimatedFeeAmount, Errors.InsufficientFunds());
        } else {
            // Reject msg.value to prevent accidental native loss; bridges are not expected to require both native
            // and ERC-20 fees simultaneously.
            require(msg.value == 0, Errors.InvalidParameter());
            if (estimatedFeeAmount > 0) {
                IERC20(ccipFeeParams.feeToken).safeTransferFrom(feePayer, address(this), estimatedFeeAmount);
            }
        }

        _pullAssetFromTransferHelperAndApproveCcipRouter(
            assetToBridge, amountToBridge, ccipFeeParams.feeToken, estimatedFeeAmount
        );

        _sendMessageWithFeePayer(
            chainSelector,
            ccipMessage,
            feePayer,
            ccipFeeParams.feeToken,
            ccipFeeParams.nativeFeeRefundThreshold,
            estimatedFeeAmount
        );

        _assertCcipRouterAllowancesAreFullyConsumed(assetToBridge, amountToBridge, ccipFeeParams.feeToken);
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message) external override nonReentrant onlyRouter {
        // Only process messages if the sender from the source chain is the recognized adapter.
        _validateMessageSource(message);
        _processMessage(message);
        emit MessageReceived(message.messageId);
    }

    /// @inheritdoc ICcipBridgeAdapter
    function replayFundsReceiving(address asset, uint256 amount) external override nonReentrant restricted {
        _transferToTransferHelper(asset, amount);
        IChainGateway(GATEWAY).receiveMessage(RECEIVED_FUNDS_ONLY_SOURCE_CHAIN_ID, asset, amount, "");
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _processMessage(Client.Any2EVMMessage memory message) internal {
        uint256 tokenCount = message.destTokenAmounts.length;
        require(tokenCount < 2, InvalidTokenCount());
        uint256 sourceChainId = _chainIdOf[message.sourceChainSelector];

        address asset = Constants.ASSET_FOR_DATA_ONLY_BRIDGE;
        uint256 amount = 0;
        if (tokenCount == 1) {
            asset = message.destTokenAmounts[0].token;
            amount = message.destTokenAmounts[0].amount;
            _transferToTransferHelper(asset, amount);
        }
        IChainGateway(GATEWAY).receiveMessage(sourceChainId, asset, amount, message.data);
    }

    function _pullAssetFromTransferHelperAndApproveCcipRouter(
        address asset,
        uint256 amount,
        address feeToken,
        uint256 estimatedFeeAmount
    ) internal {
        if (feeToken == asset && amount > 0) {
            // Bridged asset and fee share the same ERC-20: a single allowance covers both legs.
            ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
            IERC20(asset).forceApprove(CCIP_ROUTER, amount + estimatedFeeAmount);
        } else {
            if (amount > 0) {
                ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
                IERC20(asset).forceApprove(CCIP_ROUTER, amount);
            }
            if (feeToken != Constants.NATIVE_CURRENCY) {
                IERC20(feeToken).forceApprove(CCIP_ROUTER, estimatedFeeAmount);
            }
        }
    }

    /// @dev Defensive assertion that the CCIP router fully consumed every allowance set by
    /// `_pullAssetFromTransferHelperAndApproveCcipRouter`. The router is expected to pull the exact approved
    /// amounts during `ccipSend`; any leftover allowance signals a router behavior the adapter does not
    /// account for, so revert rather than silently leave a stale approval.
    function _assertCcipRouterAllowancesAreFullyConsumed(address asset, uint256 amount, address feeToken)
        internal
        view
    {
        if (amount > 0) {
            _requireZeroCcipRouterAllowance(asset);
        }
        // When `feeToken == asset && amount > 0`, the asset check above already covered the shared allowance.
        if (feeToken != Constants.NATIVE_CURRENCY && feeToken != asset) {
            _requireZeroCcipRouterAllowance(feeToken);
        }
    }

    function _requireZeroCcipRouterAllowance(address token) internal view {
        uint256 remainingAllowance = IERC20(token).allowance(address(this), CCIP_ROUTER);
        require(remainingAllowance == 0, UnexpectedCcipRouterAllowance(token, remainingAllowance));
    }

    function _sendMessageWithFeePayer(
        uint64 chainSelector,
        Client.EVM2AnyMessage memory message,
        address feePayer,
        address feeToken,
        uint256 nativeFeeRefundThreshold,
        uint256 estimatedFeeAmount
    ) internal {
        bytes32 messageId = IRouterClient(CCIP_ROUTER)
        .ccipSend{value: feeToken == Constants.NATIVE_CURRENCY ? estimatedFeeAmount : 0}(
            chainSelector, message
        );
        if (feeToken == Constants.NATIVE_CURRENCY && msg.value > estimatedFeeAmount) {
            uint256 excessFee = msg.value - estimatedFeeAmount;
            if (excessFee >= nativeFeeRefundThreshold) {
                _triggerNativeFeeRefund(feePayer, excessFee);
            }
        }
        emit MessagePublished(messageId);
    }

    function _triggerNativeFeeRefund(address feePayer, uint256 excessFee) internal {
        (bool callSucceeded,) = payable(feePayer).call{value: excessFee}("");
        require(callSucceeded, Errors.NativeTransferFailed());
        emit FeeRefunded(feePayer, Constants.NATIVE_CURRENCY, excessFee);
    }

    function _validateMessageSource(Client.Any2EVMMessage calldata message) internal view {
        uint256 chainIdFromMessageChainSelector = _chainIdOf[message.sourceChainSelector];
        address destinationChainAdapter = _destinationChainAdapterOf[chainIdFromMessageChainSelector];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());
        require(
            message.sourceChainSelector == _chainSelectorOf[chainIdFromMessageChainSelector], Errors.InvalidParameter()
        );
        require(_safeAbiDecodeEvmSender(message.sender) == destinationChainAdapter, OnlyDestinationChainAdapter());
    }

    function _safeAbiDecodeEvmSender(bytes calldata abiEncodedEvmSender) internal pure returns (address) {
        require(
            abiEncodedEvmSender.length == Constants.ABI_ENCODED_EVM_ADDRESS_BYTE_LENGTH,
            ICcipBridgeAdapter.UnexpectedDataLength()
        );
        bytes32 value = bytes32(abiEncodedEvmSender[0:Constants.ABI_ENCODED_EVM_ADDRESS_BYTE_LENGTH]);
        require((value & Constants.ABI_ENCODED_EVM_ADDRESS_MASK) == value, Errors.InvalidParameter());
        return abi.decode(abiEncodedEvmSender, (address));
    }

    receive() external payable {}

    function _beforeRescueNative(uint256) internal virtual override {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }

    function _beforeRescueTokens(address token, uint256) internal virtual override {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
        // The adapter is not designed to hold the system's funds. The check to allow rescuing only tokens that are
        // NOT registered was added as a safeguard in case registered assets accidentally end up here, to prevent
        // taking them out of the system. Instead, they should be re-injected into the system via replayFundsReceiving.
        require(!IAssetRegistry(ASSET_REGISTRY).isAssetRegistered(token), Errors.InvalidParameter());
    }
}
