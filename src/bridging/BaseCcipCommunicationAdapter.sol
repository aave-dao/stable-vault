// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IRouterClient} from "@chainlink-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

abstract contract BaseCcipCommunicationAdapter is IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    address constant FEE_ON_NATIVE_CURRENCY = address(0);

    struct BalanceSnapshot {
        // Cumulative balance of all tokens with common denomination in RAY.
        uint256 balance;
        uint256 timestamp;
    }

    address _ccipRouter;
    address _feeToken;

    mapping(uint256 chainId => uint64 ccipChainSelector) _chainSelectorOf;
    mapping(uint64 ccipChainSelector => uint256 chainId) _chainIdOf;
    mapping(uint256 chainId => address receiver) _receiverOf;

    function ccipReceive(Client.Any2EVMMessage calldata message) external virtual override;

    function setChainSelector(uint256 chainId, uint64 ccipChainSelector) external {
        _chainSelectorOf[chainId] = ccipChainSelector;
        _chainIdOf[ccipChainSelector] = chainId;
    }

    function setChainReceiver(uint256 chainId, address receiver) external {
        _receiverOf[chainId] = receiver;
    }

    function setFeeToken(address feeToken) external {
        _feeToken = feeToken;
    }

    function setCcipRouter(address router) external {
        _ccipRouter = router;
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

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
