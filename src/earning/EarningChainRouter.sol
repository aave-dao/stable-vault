// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAllocator} from "../interfaces/IAllocator.sol";
import {IEarningChainCommuniationAdapter} from "../interfaces/IEarningChainCommuniationAdapter.sol";
import {IEarningChainRouter} from "../interfaces/IEarningChainRouter.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @title EarningChainRouter
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
contract EarningChainRouter is IEarningChainRouter {
    using SafeERC20 for IERC20;

    error UnsupportedAdapter();

    modifier onlyAdapter(address asset, uint256 fromChainId) {
        require(msg.sender == _bridgeAdapter[asset][fromChainId], UnsupportedAdapter());
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, ErrorsLib.NotAdmin());
        _;
    }

    modifier onlyManager() {
        require(msg.sender == _manager, ErrorsLib.NotManager());
        _;
    }

    /// @dev Assumes a single asset is bridged per bridge action through an adapter.
    /// @dev asset == address(0) for message-only bridging.
    /// @dev Assumes token bridges also support Arbitrary Message Bridging.
    mapping(address asset => mapping(uint256 chainId => address adapter)) _bridgeAdapter;

    address _allocator;
    address _admin;
    address _manager;
    uint256 immutable ACCOUNTING_CHAIN_ID;

    constructor(address admin, uint256 accountingChainId) {
        ACCOUNTING_CHAIN_ID = accountingChainId;
        _admin = admin;
    }

    function setManager(address manager) external onlyAdmin {
        require(manager != address(0), ErrorsLib.ZeroAddress());
        _manager = manager;
        emit ManagerSet(manager);
    }

    // TODO: Think if this should be put in constructor, or this can bee
    function setAllocator(address allocator) external onlyAdmin {
        require(allocator != address(0), ErrorsLib.ZeroAddress());
        _allocator = allocator;
        // TODO: emit
    }

    function pushToStrategy(uint256 fromChainId, address asset, uint256 amount)
        external
        onlyAdapter(asset, fromChainId)
    {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(_allocator, amount);
        IAllocator(_allocator).deposit(asset, amount);
        _sendBalanceUpdate();
    }

    function emergencyExit(uint256 amount) external onlyAdapter(address(0), ACCOUNTING_CHAIN_ID) {
        // TODO: Implement; decide which asset(s) to withdraw
        // TODO: check that the assets to withdraw from Allocator are actually bridgedable
        revert("EarningChainRouter.emergencyRouter:NOT_IMPLEMENTED");
    }

    function sendBalanceUpdate() external onlyManager {
        _sendBalanceUpdate();
    }

    // TODO: This needs to have a better name?
    function exit(address asset, uint256 amount) external onlyManager {
        IAllocator(_allocator).withdraw(asset, amount);
        _returnFunds(asset, amount);
    }

    /// @param asset asset to bridge using adapter
    /// @param chainId destination chainId
    /// @param adapter address of adapter implementing ICommunicationAdapter
    function setBridgeAdapter(address asset, uint256 chainId, address adapter) external onlyAdmin {
        address currentAdapter = _bridgeAdapter[asset][chainId];
        if (currentAdapter != adapter) {
            _bridgeAdapter[asset][chainId] = adapter;
        }
    }

    function getBridgeAdapter(address asset, uint256 chainId) external view returns (address) {
        return _bridgeAdapter[asset][chainId];
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
            ACCOUNTING_CHAIN_ID, address(0), 0, totalAssetsRay, block.timestamp
        );
    }
}
