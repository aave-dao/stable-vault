// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAllocator} from "../interfaces/IAllocator.sol";
import {IEarningChainCommuniationAdapter} from "../interfaces/IEarningChainCommuniationAdapter.sol";
import {IBridgeCommunicationHandler} from "../interfaces/IBridgeCommunicationHandler.sol";
import {IEarningChainGateway} from "../interfaces/IEarningChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventLib} from "../libraries/EventLib.sol";
import {BridgeCommunicationHandler} from "../common/BridgeCommunicationHandler.sol";

/// @title EarningChainGateway
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
contract EarningChainGateway is IEarningChainGateway, BridgeCommunicationHandler {
    using SafeERC20 for IERC20;

    modifier onlyManager() {
        require(msg.sender == _manager, ErrorsLib.NotManager());
        _;
    }

    address _allocator;
    address _manager;
    uint256 immutable ACCOUNTING_CHAIN_ID;

    constructor(address admin, uint256 accountingChainId) BridgeCommunicationHandler(admin) {
        ACCOUNTING_CHAIN_ID = accountingChainId;
    }

    function setManager(address manager) external onlyAdmin {
        require(manager != address(0), ErrorsLib.ZeroAddress());
        _manager = manager;
        emit EventLib.ManagerSet(manager);
    }

    // TODO: Think if this should be put in constructor, or this can bee
    function setAllocator(address allocator) external onlyAdmin {
        require(allocator != address(0), ErrorsLib.ZeroAddress());
        _allocator = allocator;
        emit EventLib.AllocatorSet(allocator);
    }

    /// @inheritdoc IBridgeCommunicationHandler
    function receiveFunds(uint256 sourceChainId, address asset, uint256 amount)
        external
        override
        onlyAdapter(asset, sourceChainId)
    {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(_allocator, amount);
        IAllocator(_allocator).deposit(asset, amount);
        _sendBalanceUpdate();
    }

    function emergencyExit(uint256 amount) external onlyAdapter(ASSET_FOR_MESSAGE_ONLY_BRIDGE, ACCOUNTING_CHAIN_ID) {
        (amount);
        // TODO: Implement; decide which asset(s) to withdraw
        // TODO: check that the assets to withdraw from Allocator are actually bridgedable
        revert("EarningChainGateway.emergencyRouter:NOT_IMPLEMENTED");
    }

    function sendBalanceUpdate() external onlyManager {
        _sendBalanceUpdate();
    }

    // TODO: This needs to have a better name?
    function exit(address asset, uint256 amount) external onlyManager {
        IAllocator(_allocator).withdraw(asset, amount);
        _returnFunds(asset, amount);
    }

    function _returnFunds(address asset, uint256 amount) internal {
        address adapter = _bridgeAdapter[asset][ACCOUNTING_CHAIN_ID];
        // Transfer funds to the bridge adapter
        IERC20(asset).safeTransfer(adapter, amount);
        uint256 totalAssetsRay = IAllocator(_allocator).getTotalAssets();
        IEarningChainCommuniationAdapter(adapter).sendFundsWithBalanceSnapshot(
            ACCOUNTING_CHAIN_ID, asset, amount, totalAssetsRay, block.timestamp
        );
    }

    function _sendBalanceUpdate() internal {
        address adapter = _bridgeAdapter[address(0)][ACCOUNTING_CHAIN_ID];
        uint256 totalAssetsRay = IAllocator(_allocator).getTotalAssets();
        IEarningChainCommuniationAdapter(adapter).sendFundsWithBalanceSnapshot(
            ACCOUNTING_CHAIN_ID, ASSET_FOR_MESSAGE_ONLY_BRIDGE, 0, totalAssetsRay, block.timestamp
        );
    }
}
