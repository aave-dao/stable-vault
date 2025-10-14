// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAllocator} from "../interfaces/IAllocator.sol";
import {IEarningChainCommuniationAdapter} from "../interfaces/IEarningChainCommuniationAdapter.sol";
import {IEarningChainRouter} from "../interfaces/IEarningChainRouter.sol";

/// @title EarningChainRouter
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
contract EarningChainRouter is IEarningChainRouter {
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

    // TODO: handle multiple adapters as different tokens may require different adapters
    address _adapter;
    address _allocator;
    address _manager;
    uint256 immutable ACCOUNTING_CHAIN_ID;

    constructor(uint256 accountingChainId) {
        ACCOUNTING_CHAIN_ID = accountingChainId;
    }

    function pushToStrategy(uint256 fromChainId, address asset, uint256 amount) external onlyAdapter(fromChainId) {
        IERC20(asset).safeTransferFrom(msg.sender, _allocator, amount);
        IAllocator(_allocator).deposit(asset, amount);
        _sendBalanceUpdate();
    }

    function sendBalanceUpdate() external onlyManager {
        _sendBalanceUpdate();
    }

    // TODO: This needs to have a better name?
    function exit(address asset, uint256 amount) external onlyManager {
        IAllocator(_allocator).withdraw(asset, amount);
        _returnFunds(asset, amount);
    }

    function emergencyExit(uint256 amount) external onlyAdapter(ACCOUNTING_CHAIN_ID) {
        // TODO: Implement; decide which asset(s) to withdraw
        // TODO: check that the assets to withdraw from Allocator are actually bridgedable
    }

    function _returnFunds(address asset, uint256 amount) internal {
        // TODO: handle adapter for given token
        address adapter = _adapter;
        // Transfer funds to the bridge adapter
        IERC20(asset).safeTransfer(adapter, amount);
        uint256 totalAssetsRay = IAllocator(_allocator).getTotalAssets();
        IEarningChainCommuniationAdapter(_adapter).sendFundsWithBalanceSnapshot(ACCOUNTING_CHAIN_ID, asset, amount, totalAssetsRay, block.timestamp);   
    }

    function _sendBalanceUpdate() internal {
        uint256 totalAssetsRay = IAllocator(_allocator).getTotalAssets();
        IEarningChainCommuniationAdapter(_adapter).sendFundsWithBalanceSnapshot(ACCOUNTING_CHAIN_ID, address(0), 0, totalAssetsRay, block.timestamp);
    }
}
