// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICommunicationHandler} from "../interfaces/ICommunicationHandler.sol";
import {ICommunicationAdapter} from "../interfaces/ICommunicationAdapter.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";

// Earning Chain version of CommunicationHandler
contract EarningChainRouter {
    using SafeERC20 for IERC20;

    error UnsupportedAdapter();
    error NotManager();

    modifier onlyAdapter(uint256 fromChainId) {
        require(msg.sender == _adapter, UnsupportedAdapter());
        _;
    }

    modifier onlyManager() {
        require(msg.sender == _manager, NotManager());
        _;
    }

    address _adapter;
    address _allocator;
    address _manager;
    uint256 immutable ACCOUNTING_CHAIN_ID;

    constructor(uint256 accountingChainId) {
        ACCOUNTING_CHAIN_ID = accountingChainId;
    }

    function pushToStrategy(uint256 fromChainId, address asset, uint256 amount) external onlyAdapter(fromChainId) {
        IERC20(asset).safeTransferFrom(msg.sender, _allocator, amount);
        // TODO: Add a try-catch
        IAllocator(_allocator).deposit(asset, amount);
        _sendBalanceUpdateBack();
    }

    function _sendBalanceUpdateBack() internal {
        uint256 totalAssets = IAllocator(_allocator).getTotalAssets();
        ICommunicationAdapter(_adapter).sendMessage(
            ACCOUNTING_CHAIN_ID, abi.encode(ICommunicationHandler.MessageType.BALANCE_UPDATE, totalAssets)
        );
    }

    // TODO: This needs to have a better name?
    function exit(address asset, uint256 amount) external onlyManager {
        IAllocator(_allocator).withdraw(asset, amount);
        IERC20(asset).safeTransferFrom(_allocator, msg.sender, amount);
        uint256 totalAssets = IAllocator(_allocator).getTotalAssets();
        bytes[] memory messages = new bytes[](2);
        messages[0] =
            abi.encode(ICommunicationHandler.MessageType.BALANCE_UPDATE, abi.encode(totalAssets, block.timestamp)); // Balance Update
        messages[1] = abi.encode(ICommunicationHandler.MessageType.TRANSFER, abi.encode(block.chainid, asset, amount));
        ICommunicationAdapter(_adapter).sendFunds(ACCOUNTING_CHAIN_ID, asset, amount, abi.encode(messages));
    }

    function emergencyExit(address asset, uint256 amount) external onlyAdapter(ACCOUNTING_CHAIN_ID) {
        // TODO: Implement
    }
}
