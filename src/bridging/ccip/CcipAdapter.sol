// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {BaseBridgeAdapter} from "src/bridging/BaseBridgeAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title CcipAdapter
/// @author Aave Labs
/// @notice Adapter for sending and receiving messages via Chainlink CCIP.
/// @dev This adapter will not ingest user-specific tokens and data, therefore the adapter does not support
/// returning tokens to the original sender on the source chain (original sender will be the source chain CCIP adapter).
contract CcipAdapter is BaseBridgeAdapter, ReentrancyGuard, ICcipBridgeAdapter, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    /// @notice Amount of gas to reserve during ccipReceive() to properly handle processing of failed messages.
    uint256 internal constant MIN_FAILURE_HANDLING_GAS_RESERVATION = 45_000;

    address internal immutable CCIP_ROUTER;

    mapping(uint256 chainId => uint64 ccipChainSelector) internal _chainSelectorOf;
    mapping(uint64 ccipChainSelector => uint256 chainId) internal _chainIdOf;
    mapping(bytes32 messageId => ICcipBridgeAdapter.MessageDataStatus messageDataStatus) internal _messageStatusOf;
    mapping(bytes32 messageId => Client.Any2EVMMessage message) internal _messageOf;

    modifier onlyRouter() {
        require(msg.sender == CCIP_ROUTER, OnlyBridgeRouter());
        _;
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param gateway Address of the Gateway contract.
    /// @param ccipRouter Address of the Chainlink CCIP router.
    /// @param transferHelper Address of the TransferHelper contract.
    constructor(address accessManager, address gateway, address ccipRouter, address transferHelper)
        BaseBridgeAdapter(accessManager, gateway, transferHelper)
    {
        CCIP_ROUTER = ccipRouter;
    }

    /// @inheritdoc ICcipBridgeAdapter
    function getRouter() external view override returns (address) {
        return address(CCIP_ROUTER);
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
    function getRetryableMessage(bytes32 messageId) external view override returns (Client.Any2EVMMessage memory) {
        return _messageOf[messageId];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function retryMessage(bytes32 messageId) external override nonReentrant restricted {
        if (!_isMessageRetryable(messageId)) {
            revert MessageNotRetryable(messageId);
        }
        Client.Any2EVMMessage memory message = _messageOf[messageId];
        _messageStatusOf[messageId] = ICcipBridgeAdapter.MessageDataStatus.PROCESSED;
        _processMessage(message);
        emit MessageSucceeded(messageId);
        delete _messageOf[messageId];
        delete _messageStatusOf[messageId];
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external override restricted {
        _chainSelectorOf[chainId] = ccipChainSelector;
        _chainIdOf[ccipChainSelector] = chainId;
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory data,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        address destinationChainAdapter = _destinationChainAdapterOf[destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());

        Client.EVMTokenAmount[] memory tokenAmounts;
        if (asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE) {
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: amount});
            ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
            IERC20(asset).forceApprove(CCIP_ROUTER, amount);
        } else {
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

        ITransferHelper(TRANSFER_HELPER).pull(bridgeParams.feeToken, bridgeParams.feeAmount);
        if (bridgeParams.feeToken != Constants.NATIVE_CURRENCY) {
            // Increase allowance in case of the fee token matching an asset being bridged.
            IERC20(bridgeParams.feeToken).safeIncreaseAllowance(CCIP_ROUTER, bridgeParams.feeAmount);
        }

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationChainAdapter),
            data: data,
            tokenAmounts: tokenAmounts,
            feeToken: bridgeParams.feeToken,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: bridgeParams.gasLimit, allowOutOfOrderExecution: true})
            )
        });
        _sendMessageWithFeePayer(
            destinationChainId,
            ccipMessage,
            bridgeParams.feePayer,
            bridgeParams.feeToken,
            bridgeParams.feeAmount,
            bridgeParams.feeRefundThreshold
        );
        if (bridgeParams.feeToken != Constants.NATIVE_CURRENCY) {
            // Reset allowance to avoid any remaining allowance on the fee token to the CCIP Router.
            IERC20(bridgeParams.feeToken).forceApprove(CCIP_ROUTER, 0);
        }
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message) external override nonReentrant onlyRouter {
        emit MessageReceived(message.messageId);
        // Only process messages if the sender from the source chain is the recognized adapter.
        _validateMessageSource(message);

        // Reserve gas for failure handling.
        uint256 gasLimit = gasleft();
        unchecked {
            if (gasLimit < MIN_FAILURE_HANDLING_GAS_RESERVATION) {
                revert CCIPDefensiveReceiverInsufficientGas();
            }
            gasLimit -= MIN_FAILURE_HANDLING_GAS_RESERVATION;
        }

        try this.processMessage(message) {
            emit MessageSucceeded(message.messageId);
        } catch (bytes memory err) {
            _messageStatusOf[message.messageId] = ICcipBridgeAdapter.MessageDataStatus.FAILED;
            _messageOf[message.messageId] = message;
            emit MessageFailed(message.messageId, err);
        }
    }

    function processMessage(Client.Any2EVMMessage calldata message) external onlySelf {
        _processMessage(message);
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _processMessage(Client.Any2EVMMessage memory message) internal {
        // Process data first to allow any potential state modifications to take place before processing tokens.
        // Assumes if data is sent with tokens, then the data must be processed first.
        if (message.data.length > 0) {
            _messageStatusOf[message.messageId] = ICcipBridgeAdapter.MessageDataStatus.PROCESSED;
            IChainGateway(GATEWAY)
                .receiveMessage(
                    _chainIdOf[message.sourceChainSelector], Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, message.data
                );
        }
        if (message.destTokenAmounts.length > 0) {
            for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
                address asset = message.destTokenAmounts[i].token;
                uint256 amount = message.destTokenAmounts[i].amount;
                _processReceivedFunds(asset, amount);
            }
        }
    }

    function _isMessageRetryable(bytes32 messageId) internal view returns (bool) {
        return _messageStatusOf[messageId] == ICcipBridgeAdapter.MessageDataStatus.FAILED
            && _messageOf[messageId].messageId == messageId;
    }

    function _sendMessageWithFeePayer(
        uint256 chainId,
        Client.EVM2AnyMessage memory message,
        address feePayer,
        address feeToken,
        uint256 allocatedFeeAmount,
        uint256 feeRefundThreshold
    ) internal {
        uint64 chainSelector = _chainSelectorOf[chainId];
        uint256 estimatedFeeAmount = IRouterClient(CCIP_ROUTER).getFee(chainSelector, message);
        uint256 msgValue;
        if (feeToken == Constants.NATIVE_CURRENCY) {
            msgValue = estimatedFeeAmount;
        }
        if (allocatedFeeAmount > estimatedFeeAmount) {
            uint256 excessFee = allocatedFeeAmount - estimatedFeeAmount;
            if (excessFee > feeRefundThreshold) {
                _triggerFeeRefund(feePayer, feeToken, excessFee);
            }
        }
        bytes32 messageId = IRouterClient(CCIP_ROUTER).ccipSend{value: msgValue}(chainSelector, message);
        emit MessagePublished(messageId);
    }

    function _triggerFeeRefund(address feePayer, address feeToken, uint256 excessFee) internal {
        if (feeToken == Constants.NATIVE_CURRENCY) {
            payable(feePayer).transfer(excessFee);
        } else {
            IERC20(feeToken).safeTransfer(feePayer, excessFee);
        }
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
}
