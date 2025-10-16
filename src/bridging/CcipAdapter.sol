// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

contract CcipAdapter is IBridgeAdapter, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    address internal constant FEE_ON_NATIVE_CURRENCY = address(0);

    address internal _ccipRouter;
    address internal _feeToken;
    address internal _gateway;

    mapping(uint256 chainId => uint64 ccipChainSelector) internal _chainSelectorOf;
    mapping(uint64 ccipChainSelector => uint256 chainId) internal _chainIdOf;
    mapping(uint256 chainId => address receiver) internal _receiverOf;

    modifier onlyGateway() {
        require(msg.sender == _gateway, ErrorsLib.NotGateway());
        _;
    }

    // TODO: add admin modifier
    function setGateway(address gateway) external {
        _gateway = gateway;
    }

    // TODO: add admin modifier
    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external {
        _chainSelectorOf[chainId] = ccipChainSelector;
        _chainIdOf[ccipChainSelector] = chainId;
    }

    // TODO: add admin modifier
    function setChainReceiver(uint256 chainId, address receiver) external {
        _receiverOf[chainId] = receiver;
    }

    // TODO: add admin modifier
    function setFeeToken(address feeToken) external {
        _feeToken = feeToken;
    }

    // TODO: add admin modifier
    function setCcipRouter(address router) external {
        _ccipRouter = router;
    }

    // TODO: expose admin function for destination chain replays of bridge data
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        // TODO: Verify it's coming from a proper sender on the other chain
        if (message.destTokenAmounts.length > 0) {
            _processFundsReceiving(message.sourceChainSelector, message.destTokenAmounts);
        }
        if (message.data.length > 0) {
            IChainGateway(_gateway).receiveMessage(
                _chainIdOf[message.sourceChainSelector], new IBridgeAdapter.BridgeAsset[](0), message.data
            );
        }
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChain(uint256 chainId, BridgeAsset[] memory assets, bytes memory data)
        external
        override
        onlyGateway
    {
        uint256 gasLimit = 2_000_000;
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](assets.length);
        if (assets.length > 0) {
            require(assets.length == 1, ErrorsLib.InvalidBridgeAssetsLength());
            address asset = assets[0].asset;
            uint256 amount = assets[0].amount;
            // TODO: should the Bridge Adapter pull funds from caller as opposed to trusting funds were sent?
            IERC20(asset).forceApprove(_ccipRouter, amount);
            tokenAmounts[0] = Client.EVMTokenAmount({token: asset, amount: amount});
            gasLimit = 3_000_000;
        }
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiverOf[chainId]),
            data: data,
            tokenAmounts: tokenAmounts,
            feeToken: _feeToken,
            // TODO: Think how we pass this gasLimit down here
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: false}))
        });
        _sendMessage(chainId, ccipMessage);
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

    function _processFundsReceiving(uint64 sourceChainSelector, Client.EVMTokenAmount[] memory assetsToReceive)
        internal
    {
        for (uint256 i = 0; i < assetsToReceive.length; i++) {
            address asset = assetsToReceive[i].token;
            uint256 amount = assetsToReceive[i].amount;
            IERC20(asset).forceApprove(_gateway, amount);
            IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
            assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
            IChainGateway(_gateway).receiveMessage(_chainIdOf[sourceChainSelector], assets, "");
        }
    }
}
