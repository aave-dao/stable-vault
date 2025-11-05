// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "../interfaces/ICcipBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {BaseBridgeAdapter} from "./BaseBridgeAdapter.sol";

/// @title CcipAdapter
///
/// @notice Adapter for sending and receiving messages via Chainlink CCIP.
contract CcipAdapter is BaseBridgeAdapter, ICcipBridgeAdapter, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    address internal constant FEE_ON_NATIVE_CURRENCY = address(0);

    address internal immutable CCIP_ROUTER;
    address internal _feeToken;

    mapping(uint256 chainId => uint64 ccipChainSelector) internal _chainSelectorOf;
    mapping(uint64 ccipChainSelector => uint256 chainId) internal _chainIdOf;

    modifier onlyRouter() {
        require(msg.sender == CCIP_ROUTER, NotBridgeRouter());
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert ErrorsLib.NotSelf();
        }
        _;
    }

    constructor(address accessManager, address gateway, address ccipRouter) BaseBridgeAdapter(accessManager, gateway) {
        CCIP_ROUTER = ccipRouter;
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external override restricted {
        _chainSelectorOf[chainId] = ccipChainSelector;
        _chainIdOf[ccipChainSelector] = chainId;
    }

    /// @inheritdoc ICcipBridgeAdapter
    function setFeeToken(address feeToken) external override restricted {
        _feeToken = feeToken;
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data,
        IChainGateway.BridgeAdapterParams memory bridgeAdapterParams
    ) external payable override onlyGateway {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](assets.length);
        if (assets.length > 0) {
            for (uint256 i = 0; i < assets.length; i++) {
                address asset = assets[i].asset;
                uint256 amount = assets[i].amount;
                // Pull funds from caller into this contract
                IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
                // Approve the CCIP Router to spend the funds
                IERC20(asset).forceApprove(CCIP_ROUTER, amount);
                tokenAmounts[i] = Client.EVMTokenAmount({token: asset, amount: amount});
            }
        }
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_destinationChainAdapterOf[destinationChainId]),
            data: data,
            tokenAmounts: tokenAmounts,
            feeToken: bridgeAdapterParams.bridgeFeeToken,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: bridgeAdapterParams.tripGasLimit, allowOutOfOrderExecution: false})
            )
        });
        _sendMessageWithFeePayer(
            destinationChainId,
            ccipMessage,
            bridgeAdapterParams.bridgeFeePayer,
            bridgeAdapterParams.bridgeFeeToken,
            bridgeAdapterParams.bridgeFeeAmount
        );
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message) external override onlyRouter {
        if (message.data.length > 0) {
            require(
                abi.decode(message.sender, (address))
                    == _destinationChainAdapterOf[_chainIdOf[message.sourceChainSelector]],
                ErrorsLib.NotDestinationChainAdapter()
            );
            IChainGateway(GATEWAY)
                .receiveMessage(
                    _chainIdOf[message.sourceChainSelector], new IBridgeAdapter.BridgeAsset[](0), message.data
                );
        }
        if (message.destTokenAmounts.length > 0) {
            try this.processReceivedFunds(_chainIdOf[message.sourceChainSelector], message.destTokenAmounts) {}
            catch (bytes memory err) {
                emit BridgedFundsProcessingFailed(_chainIdOf[message.sourceChainSelector], abi.encode(message), err);
            }
        }
    }

    function processReceivedFunds(uint256 sourceChainId, Client.EVMTokenAmount[] memory assetsToProcess)
        external
        onlySelf
    {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](assetsToProcess.length);
        for (uint256 i = 0; i < assetsToProcess.length; i++) {
            address asset = assetsToProcess[i].token;
            uint256 amount = assetsToProcess[i].amount;
            assets[i] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        }
        _processReceivedFunds(sourceChainId, assets);
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _sendMessage(uint256 chainId, Client.EVM2AnyMessage memory message) internal {
        uint64 chainSelector = _chainSelectorOf[chainId];
        uint256 fee = IRouterClient(CCIP_ROUTER).getFee(chainSelector, message);
        uint256 msgValue;
        if (message.feeToken == FEE_ON_NATIVE_CURRENCY) {
            msgValue = fee;
        } else {
            IERC20(_feeToken).safeIncreaseAllowance(CCIP_ROUTER, fee);
        }
        IRouterClient(CCIP_ROUTER).ccipSend{value: msgValue}(chainSelector, message);
    }

    function _sendMessageWithFeePayer(
        uint256 chainId,
        Client.EVM2AnyMessage memory message,
        address feePayer,
        address feeToken,
        uint256 allocatedFeeAmount
    ) internal {
        uint64 chainSelector = _chainSelectorOf[chainId];
        uint256 estimatedFeeAmount = IRouterClient(CCIP_ROUTER).getFee(chainSelector, message);
        uint256 msgValue;
        if (feeToken == FEE_ON_NATIVE_CURRENCY) {
            msgValue = estimatedFeeAmount;
        } else {
            // Pull the fee amount from the sender into this contract.
            IERC20(feeToken).safeTransferFrom(msg.sender, address(this), estimatedFeeAmount);
            // Approve the Router to pull the estimated fee.
            IERC20(feeToken).safeIncreaseAllowance(CCIP_ROUTER, estimatedFeeAmount);
        }
        // Return any excess fee to the fee payer.
        if (allocatedFeeAmount > estimatedFeeAmount) {
            if (feeToken == FEE_ON_NATIVE_CURRENCY) {
                payable(feePayer).transfer(allocatedFeeAmount - estimatedFeeAmount);
            } else {
                IERC20(feeToken).safeTransfer(feePayer, allocatedFeeAmount - estimatedFeeAmount);
            }
        }
        IRouterClient(CCIP_ROUTER).ccipSend{value: msgValue}(chainSelector, message);
    }
}
