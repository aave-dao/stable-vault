// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {BaseBridgeAdapter} from "./BaseBridgeAdapter.sol";

/// @title CcipAdapter
/// @notice Adapter for sending and receiving messages via Chainlink CCIP.
contract CcipAdapter is BaseBridgeAdapter, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    address internal constant FEE_ON_NATIVE_CURRENCY = address(0);

    address internal immutable _ccipRouter;
    address internal _feeToken;

    mapping(uint256 chainId => uint64 ccipChainSelector) internal _chainSelectorOf;
    mapping(uint64 ccipChainSelector => uint256 chainId) internal _chainIdOf;
    mapping(uint256 chainId => address receiver) internal _receiverOf;

    modifier onlyRouter() {
        require(msg.sender == _ccipRouter, NotBridgeRouter());
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert ErrorsLib.NotSelf();
        }
        _;
    }

    constructor(address owner, address ccipRouter) BaseBridgeAdapter(owner) {
        require(ccipRouter != address(0), ErrorsLib.ZeroAddress());
        _ccipRouter = ccipRouter;
    }

    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external onlyOwner {
        _chainSelectorOf[chainId] = ccipChainSelector;
        _chainIdOf[ccipChainSelector] = chainId;
    }

    function setChainReceiver(uint256 chainId, address receiver) external onlyOwner {
        _receiverOf[chainId] = receiver;
    }

    function setFeeToken(address feeToken) external onlyOwner {
        _feeToken = feeToken;
    }

    /// @inheritdoc BaseBridgeAdapter
    function publishMessageToChain(uint256 chainId, BridgeAsset[] memory assets, bytes memory data)
        external
        override
        onlyGateway
    {
        uint256 gasLimit = 2_000_000;
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](assets.length);
        if (assets.length > 0) {
            gasLimit = 3_000_000;
            for (uint256 i = 0; i < assets.length; i++) {
                address asset = assets[i].asset;
                uint256 amount = assets[i].amount;
                // Pull funds from caller into this contract
                IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
                // Approve the CCIP Router to spend the funds
                IERC20(asset).forceApprove(_ccipRouter, amount);
                tokenAmounts[i] = Client.EVMTokenAmount({token: asset, amount: amount});
            }
        }
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiverOf[chainId]),
            data: data,
            tokenAmounts: tokenAmounts,
            feeToken: _feeToken,
            // TODO: Think how we pass this gasLimit down here
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: false})
            )
        });
        _sendMessage(chainId, ccipMessage);
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message) external override onlyRouter {
        if (message.data.length > 0) {
            IChainGateway(_gateway)
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
        uint256 fee = IRouterClient(_ccipRouter).getFee(chainSelector, message);
        uint256 msgValue;
        if (message.feeToken == FEE_ON_NATIVE_CURRENCY) {
            msgValue = fee;
        } else {
            IERC20(_feeToken).safeIncreaseAllowance(_ccipRouter, fee);
        }
        IRouterClient(_ccipRouter).ccipSend{value: msgValue}(chainSelector, message);
    }
}
