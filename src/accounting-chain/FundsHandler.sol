// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFundsHandler} from "./interfaces/IFundsHandler.sol";
import {IWithdrawalPriorityQueue} from "./interfaces/IWithdrawalPriorityQueue.sol";
import {ICommunicationHandler} from "./interfaces/ICommunicationHandler.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {IAllocator} from "./interfaces/IAllocator.sol";

import {AssetLib} from "../libraries/AssetLib.sol";

// Consider making it a library instead
contract FundsHandler is IFundsHandler {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    struct ChainBalanceSnapshot {
        uint256 balanceSnapshot;
        uint256 snapshotTimestamp;
    }

    struct WithdrawalRequest {
        address user;
        uint256 amountRequested;
        uint256 amountGuaranteed;
        address preferredAsset;
        uint256 requestTimestamp;
        bytes data;
    }

    mapping(uint256 chainId => ChainBalanceSnapshot chainBalance) chainBalances;

    mapping(uint256 withdrawalRequestId => WithdrawalRequest) internal _withdrawalRequests;
    uint256 internal _lastWithdrawalRequestId;
    IWithdrawalPriorityQueue internal _queue;
    address manager;
    address basedBoostedVault;
    address communicationHandler;
    address allocator;

    modifier onlyManager() {
        require(msg.sender == address(manager), ErrorsLib.NotManager());
        _;
    }

    modifier onlyBaseBoostedVault() {
        require(msg.sender == basedBoostedVault, OnlyBaseBoostedVault());
        _;
    }

    modifier onlyCommunicationHandler() {
        // TODO: Implement it
        _;
    }

    constructor(address _manager, address _basedBoostedVault, address _communicationHandler, address _allocator) {
        require(_manager != address(0), ErrorsLib.ZeroAddress());
        manager = _manager;
        basedBoostedVault = _basedBoostedVault;
        communicationHandler = _communicationHandler;
        allocator = _allocator;
    }

    function processWithdrawalRequest(
        address user,
        uint256 amount,
        uint256 guaranteedAmount,
        address preferredAsset,
        bytes calldata /* data */
    ) external override onlyBaseBoostedVault returns (uint256) {
        uint256 withdrawalRequestId = ++_lastWithdrawalRequestId;
        _withdrawalRequests[withdrawalRequestId] =
            WithdrawalRequest(user, amount, guaranteedAmount, preferredAsset, block.timestamp, "");
        // TODO: Implement anything else if needed
        return withdrawalRequestId;
    }

    function processDeposit(address user, address asset, uint256 amount) external override onlyBaseBoostedVault {
        (user);
        // TODO: Implement
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    function processWithdrawalExecution(uint256 withdrawalRequestId, bytes calldata /* data */ )
        external
        override
        onlyBaseBoostedVault
        returns (uint256, bytes memory)
    {
        _verifyIfRequestCanBeProcessed(withdrawalRequestId);
        uint256 amount = _executeWithdrawal(withdrawalRequestId);
        return (amount, "");
    }

    function _executeWithdrawal(uint256 withdrawalRequestId) internal returns (uint256) {
        address asset = _withdrawalRequests[withdrawalRequestId].preferredAsset;
        uint256 amount = _withdrawalRequests[withdrawalRequestId].amountRequested.rayToAssetDecimals(asset);
        address destination = _withdrawalRequests[withdrawalRequestId].user;
        delete _withdrawalRequests[withdrawalRequestId];
        _pullFundsFromImmediateLiquidity(asset, amount);
        IERC20(asset).safeTransfer(destination, amount);
        return amount;
    }

    function _verifyIfRequestCanBeProcessed(uint256 withdrawalRequestId) internal view {
        // TODO: Implement
        // require(IWithdrawalPriorityQueue(_queue).canBeExecuted(withdrawalRequestId));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Pushes funds to Allocator.
    function _pushFundsToImmediateLiquidity(address asset, uint256 amount) internal {
        IERC20(asset).forceApprove(allocator, amount);
        IAllocator(allocator).deposit(asset, amount);
    }

    /// @notice Takes from Allocator and gets ERC20 for further action.
    function _pullFundsFromImmediateLiquidity(address asset, uint256 amount) internal {
        IAllocator(allocator).withdraw(asset, amount);
    }

    // Manager Functions

    function pushFundsToChain(address asset, uint256 amount, uint256 chainId) external onlyManager {
        _pullFundsFromImmediateLiquidity(asset, amount);
        ICommunicationHandler(communicationHandler).sendPushFundsToChainMessage(asset, amount, chainId);
    }

    function pullFundsFromChain(uint256 amount, uint256 chainId) external onlyManager {
        ICommunicationHandler(communicationHandler).sendPullFundsFromChainMessage(amount, chainId);
    }

    function updateChainBalanceCallback(uint256 chainId, uint256 balanceSnapshot, uint256 snapshotTimestamp)
        external
        onlyCommunicationHandler
    {
        _updateChainBalance(chainId, balanceSnapshot, snapshotTimestamp);
    }

    function fundsArrivedFromChainCallback(uint256 chainId, address asset, uint256 amount)
        external
        onlyCommunicationHandler
    {
        (chainId);
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    //////

    function _updateChainBalance(uint256 chainId, uint256 balanceSnapshot, uint256 snapshotTimestamp) internal {
        if (chainBalances[chainId].snapshotTimestamp < snapshotTimestamp) {
            chainBalances[chainId] =
                ChainBalanceSnapshot({balanceSnapshot: balanceSnapshot, snapshotTimestamp: snapshotTimestamp});
        }
    }
}
