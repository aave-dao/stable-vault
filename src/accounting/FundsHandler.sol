// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {IWithdrawalPriorityQueue} from "../interfaces/IWithdrawalPriorityQueue.sol";
import {ICommunicationHandler} from "../interfaces/ICommunicationHandler.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";

import {AssetLib} from "../libraries/AssetLib.sol";

// Consider making it a library instead
contract FundsHandler is IFundsHandler {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    struct ChainBalanceSnapshot {
        uint256 chainId;
        // Assumes all balances have common denomination.
        uint256 amountRay;
        uint256 timestamp;
    }

    struct WithdrawalRequest {
        address recipient;
        uint256 amountRequested;
        uint256 amountGuaranteed;
        address preferredAsset;
        uint256 requestTimestamp;
        bytes data;
    }

    ChainBalanceSnapshot[] internal _chainBalances;
    mapping(uint256 withdrawalRequestId => WithdrawalRequest) internal _withdrawalRequests;
    uint256 internal _lastWithdrawalRequestId;
    IWithdrawalPriorityQueue internal _queue;
    address _manager;
    address _basedBoostedVault;
    address _communicationHandler;
    address _allocator;

    modifier onlyManager() {
        require(msg.sender == address(_manager), ErrorsLib.NotManager());
        _;
    }

    modifier onlyBaseBoostedVault() {
        require(msg.sender == _basedBoostedVault, OnlyBaseBoostedVault());
        _;
    }

    modifier onlyCommunicationHandler() {
        require(msg.sender == _communicationHandler, OnlyCommunicationHandler());
        _;
    }

    constructor(address manager, address basedBoostedVault, address communicationHandler, address allocator) {
        require(manager != address(0), ErrorsLib.ZeroAddress());
        _manager = manager;
        _basedBoostedVault = basedBoostedVault;
        _communicationHandler = communicationHandler;
        _allocator = allocator;
    }

    function getAssetBalances() external view returns (AssetBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(_allocator).getAssets();
        AssetBalance[] memory balances = new AssetBalance[](allocatorAssets.length + _chainBalances.length);

        uint16 i = 0;
        for (uint16 j = 0; j < allocatorAssets.length; j++) {
            balances[i] = AssetBalance({
                chainId: block.chainid,
                asset: allocatorAssets[j].asset,
                amountRay: allocatorAssets[j].amount.assetDecimalsToRay(allocatorAssets[j].asset),
                timestamp: block.timestamp
            });
            i++;
        }
        for (uint16 j = 0; j < _chainBalances.length; j++) {
            balances[i] = AssetBalance({
                chainId: _chainBalances[i].chainId,
                asset: address(0),
                amountRay: _chainBalances[i].amountRay,
                timestamp: _chainBalances[i].timestamp
            });
            i++;
        }
        return balances;
    }

    function processWithdrawalRequest(
        address recipient,
        uint256 amount,
        uint256 guaranteedAmount,
        address preferredAsset,
        bytes calldata /* data */
    ) external override onlyBaseBoostedVault returns (uint256) {
        uint256 withdrawalRequestId = ++_lastWithdrawalRequestId;
        _withdrawalRequests[withdrawalRequestId] =
            WithdrawalRequest(recipient, amount, guaranteedAmount, preferredAsset, block.timestamp, "");
        // TODO: Implement anything else if needed
        return withdrawalRequestId;
    }

    function processDeposit(address asset, uint256 amount) external onlyBaseBoostedVault {
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    function processWithdrawalExecution(uint256 withdrawalRequestId, bytes calldata /* data */ )
        external
        override
        onlyBaseBoostedVault
        returns (uint256, address, bytes memory)
    {
        _verifyIfRequestCanBeProcessed(withdrawalRequestId);
        (uint256 amount, address recipient) = _executeWithdrawal(withdrawalRequestId);
        return (amount, recipient, "");
    }

    function _executeWithdrawal(uint256 withdrawalRequestId) internal returns (uint256, address) {
        address asset = _withdrawalRequests[withdrawalRequestId].preferredAsset;
        uint256 amount = _withdrawalRequests[withdrawalRequestId].amountRequested.rayToAssetDecimals(asset);
        address recipient = _withdrawalRequests[withdrawalRequestId].recipient;
        delete _withdrawalRequests[withdrawalRequestId];
        _pullFundsFromImmediateLiquidity(asset, amount);
        IERC20(asset).safeTransfer(recipient, amount);
        return (amount, recipient);
    }

    function _verifyIfRequestCanBeProcessed(uint256 withdrawalRequestId) internal view {
        // TODO: Implement
        // require(IWithdrawalPriorityQueue(_queue).canBeExecuted(withdrawalRequestId));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Pushes funds to Allocator.
    function _pushFundsToImmediateLiquidity(address asset, uint256 amount) internal {
        IERC20(asset).forceApprove(_allocator, amount);
        IAllocator(_allocator).deposit(asset, amount);
    }

    /// @notice Takes from Allocator and gets ERC20 for further action.
    function _pullFundsFromImmediateLiquidity(address asset, uint256 amount) internal {
        IAllocator(_allocator).withdraw(asset, amount);
    }

    // Manager Functions

    function pushFundsToChain(address asset, uint256 amount, uint256 chainId) external onlyManager {
        _pullFundsFromImmediateLiquidity(asset, amount);
        // TODO: Why do we use transfer but not approve here?
        IERC20(asset).safeTransfer(_communicationHandler, amount);
        ICommunicationHandler(_communicationHandler).sendPushFundsToChainMessage(asset, amount, chainId);
    }

    function pullFundsFromChain(uint256 amount, uint256 chainId) external onlyManager {
        ICommunicationHandler(_communicationHandler).sendPullFundsFromChainMessage(amount, chainId);
    }

    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalance, uint256 snapshotTimestamp)
        external
        onlyCommunicationHandler
    {
        _updateChainBalance(chainId, snapshotBalance, snapshotTimestamp);
    }

    function fundsArrivedFromChainCallback(uint256 chainId, address asset, uint256 amount)
        external
        onlyCommunicationHandler
    {
        (chainId);
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    //////

    function _updateChainBalance(uint256 chainId, uint256 snapshotBalance, uint256 snapshotTimestamp) internal {
        bool chainExists;
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            if (_chainBalances[i].chainId == chainId) {
                chainExists = true;
                if (_chainBalances[i].timestamp < snapshotTimestamp) {
                    _chainBalances[i].timestamp = snapshotTimestamp;
                    _chainBalances[i].amountRay = snapshotBalance;
                }
            }
        }
        if (!chainExists) {
            _chainBalances.push(
                ChainBalanceSnapshot({chainId: chainId, amountRay: snapshotBalance, timestamp: snapshotTimestamp})
            );
        }
    }
}
