// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
contract CcipAdapter is BaseBridgeAdapter, ICcipBridgeAdapter, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    address internal immutable CCIP_ROUTER;

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
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external override restricted {
        _chainSelectorOf[chainId] = ccipChainSelector;
        _chainIdOf[ccipChainSelector] = chainId;
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](assets.length);
        address[] memory assetsToPull = new address[](assets.length + 1);
        uint256[] memory amountsToPull = new uint256[](assets.length + 1);
        if (assets.length > 0) {
            for (uint256 i = 0; i < assets.length; i++) {
                address asset = assets[i].asset;
                uint256 amount = assets[i].amount;
                tokenAmounts[i] = Client.EVMTokenAmount({token: asset, amount: amount});

                // Approve the CCIP Router to spend the funds
                assetsToPull[i] = asset;
                amountsToPull[i] = amount;
                IERC20(asset).forceApprove(CCIP_ROUTER, amount);
            }
        }
        assetsToPull[assetsToPull.length - 1] = bridgeParams.feeToken;
        amountsToPull[amountsToPull.length - 1] = bridgeParams.feeAmount;

        if (bridgeParams.feeToken != Constants.NATIVE_CURRENCY) {
            // Increase allowance in case of the fee token matching an asset being bridged.
            IERC20(bridgeParams.feeToken).safeIncreaseAllowance(CCIP_ROUTER, bridgeParams.feeAmount);
        }
        ITransferHelper(TRANSFER_HELPER).pull(assetsToPull, amountsToPull);
        address destinationChainAdapter = _destinationChainAdapterOf[destinationChainId];
        require(destinationChainAdapter != address(0), Errors.InvalidParameter());
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
    function ccipReceive(Client.Any2EVMMessage calldata message) external override onlyRouter {
        emit MessageReceived(message.messageId);
        if (message.data.length > 0) {
            // If message processing fails, the whole bridge tx processing must fail too. We do not want to allow the
            // scenario where the funds are received, but the message is not processed successfully, as this can lead to
            // double-counting of funds, given that the balance snapshot will still reflect the funds that were just
            // received.
            _validateMessageSource(message);
            IChainGateway(GATEWAY)
                .receiveMessage(
                    _chainIdOf[message.sourceChainSelector], new IBridgeAdapter.BridgeAsset[](0), message.data
                );
        }
        if (message.destTokenAmounts.length > 0) {
            try this.processReceivedFunds(message.destTokenAmounts) {}
            catch (bytes memory err) {
                for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
                    emit TokenReceptionFailed(
                        message.messageId,
                        _chainIdOf[message.sourceChainSelector],
                        message.destTokenAmounts[i].token,
                        message.destTokenAmounts[i].amount
                    );
                }
                emit BridgedFundsProcessingFailed(
                    message.messageId, _chainIdOf[message.sourceChainSelector], abi.encode(message), err
                );
            }
        }
    }

    function processReceivedFunds(Client.EVMTokenAmount[] memory assetsToProcess) external onlySelf {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](assetsToProcess.length);
        for (uint256 i = 0; i < assetsToProcess.length; i++) {
            address asset = assetsToProcess[i].token;
            uint256 amount = assetsToProcess[i].amount;
            assets[i] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        }
        _processReceivedFunds(assets);
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
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
