// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICommunicationHandler} from "../interfaces/ICommunicationHandler.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {ICommunicationAdapter} from "../interfaces/ICommunicationAdapter.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";

contract CommunicationHandler is ICommunicationHandler {
    using SafeERC20 for IERC20;

    modifier onlyAdapter(uint256 fromChainId) {
        require(msg.sender == _adapters[fromChainId], UnsupportedAdapter());
        _;
    }

    modifier onlyFundsHandler() {
        require(msg.sender == _fundsHandler, NotFundsHandler());
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, NotAdmin());
        _;
    }

    address _fundsHandler;
    address _admin;

    mapping(uint256 chainId => address adapter) _adapters;

    constructor(address admin, address fundsHandler) {
        _admin = admin;
        _fundsHandler = fundsHandler;
    }

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId)
        external
        onlyFundsHandler
    {
        if (targetChainId == block.chainid) {
            // TODO: Is Adapter an Allocator directly or it's just a direct pass-thru?
            IERC20(asset).safeTransfer(_adapters[targetChainId], amount);
            IAllocator(_adapters[targetChainId]).deposit(asset, amount);
            return;
        }
        IERC20(asset).safeTransfer(_adapters[targetChainId], amount);
        ICommunicationAdapter(_adapters[targetChainId]).sendFunds(
            targetChainId, asset, amount, abi.encode(ICommunicationHandler.MessageType.TRANSFER, asset, amount)
        );
    }

    /// @dev Assume for Emergency withdrawal only - Earning chain will send whatever asset it prefers
    function sendPullFundsFromChainMessage(uint256 amount, uint256 targetChainId) external onlyFundsHandler {
        ICommunicationAdapter(_adapters[targetChainId]).sendMessage(
            targetChainId, abi.encode(ICommunicationHandler.MessageType.PULL_FUNDS, amount)
        );
    }

    function receiveMessage(uint256 fromChainId, bytes calldata typeAndMessageEncoded)
        external
        onlyAdapter(fromChainId)
    {
        (uint8 messageType, bytes memory message) = abi.decode(typeAndMessageEncoded, (uint8, bytes));

        if (messageType == uint8(ICommunicationHandler.MessageType.BALANCE_UPDATE)) {
            (uint256 balanceSnapshot, uint256 snapshotTimestamp) = abi.decode(message, (uint256, uint256));
            IFundsHandler(_fundsHandler).updateChainBalanceCallback(fromChainId, balanceSnapshot, snapshotTimestamp);
        } else if (messageType == uint8(ICommunicationHandler.MessageType.TRANSFER)) {
            (uint256 chainId, address asset, uint256 amount) = abi.decode(message, (uint256, address, uint256));
            IERC20(asset).safeTransfer(_fundsHandler, amount);
            IFundsHandler(_fundsHandler).fundsArrivedFromChainCallback(chainId, asset, amount);
        } else {
            revert UnsupportedMessageType();
        }
    }

    function setAdapter(uint256 chainId, address newAdapter) external onlyAdmin {
        _adapters[chainId] = newAdapter;
    }
}
