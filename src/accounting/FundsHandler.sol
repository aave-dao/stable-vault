// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAccountingChainGateway} from "../interfaces/IAccountingChainGateway.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

// TODO: consider making it a library instead
contract FundsHandler is IFundsHandler {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    struct ChainBalanceSnapshot {
        uint256 chainId;
        // Assumes all balances have common denomination.
        uint256 amountRay;
        uint256 timestamp;
    }

    ChainBalanceSnapshot[] internal _chainBalances;
    address _manager;
    address _basedBoostedVault;
    address _gateway;
    address _allocator;

    modifier onlyManager() {
        require(msg.sender == address(_manager), ErrorsLib.NotManager());
        _;
    }

    modifier onlyBaseBoostedVault() {
        require(msg.sender == _basedBoostedVault, NotBaseBoostedVault());
        _;
    }

    modifier onlyGateway() {
        require(msg.sender == _gateway, NotGateway());
        _;
    }

    constructor(address manager, address basedBoostedVault, address gateway, address allocator) {
        require(manager != address(0), ErrorsLib.ZeroAddress());
        _manager = manager;
        _basedBoostedVault = basedBoostedVault;
        _gateway = gateway;
        _allocator = allocator;
    }

    /// @inheritdoc IFundsHandler
    function getAggregatedBalance() external view returns (uint256) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(_allocator).getAssetBalances();

        uint256 totalBalanceRay;

        for (uint16 i = 0; i < allocatorAssets.length; i++) {
            totalBalanceRay += allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset);
        }
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            totalBalanceRay += _chainBalances[i].amountRay;
        }
        return totalBalanceRay;
    }

    /// @inheritdoc IFundsHandler
    function getAssetBalances() external view returns (AssetBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(_allocator).getAssetBalances();
        AssetBalance[] memory balances = new AssetBalance[](allocatorAssets.length + _chainBalances.length);
        for (uint16 i = 0; i < allocatorAssets.length; i++) {
            balances[i] = AssetBalance({
                chainId: block.chainid,
                asset: allocatorAssets[i].asset,
                amountRay: allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset),
                timestamp: block.timestamp
            });
        }
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            balances[allocatorAssets.length + i] = AssetBalance({
                chainId: _chainBalances[i].chainId,
                asset: address(0),
                amountRay: _chainBalances[i].amountRay,
                timestamp: _chainBalances[i].timestamp
            });
        }
        return balances;
    }

    /// @inheritdoc IFundsHandler
    function processDeposit(address asset, uint256 amount) external onlyBaseBoostedVault {
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    /// @inheritdoc IFundsHandler
    function processWithdrawal(address asset, uint256 amount) external override onlyBaseBoostedVault {
        _verifyAvailableLiquidity(asset, amount);
        _pullFundsFromImmediateLiquidity(asset, amount);
        IERC20(asset).forceApprove(_basedBoostedVault, amount);
    }

    /// @inheritdoc IFundsHandler
    function pullFromLiquidity(address asset, uint256 amount) external onlyBaseBoostedVault {
        _pullFundsFromImmediateLiquidity(asset, amount);
        // TODO: Check if we don't need to do increaseApproval here (re-entrancy, multi-withdrawal, etc)
        IERC20(asset).forceApprove(_basedBoostedVault, amount);
    }

    // Manager Functions

    /// @inheritdoc IFundsHandler
    function pushFundsToChain(address asset, uint256 amount, uint256 chainId) external onlyManager {
        _pullFundsFromImmediateLiquidity(asset, amount);
        IERC20(asset).forceApprove(_gateway, amount);
        IAccountingChainGateway(_gateway).sendPushFundsToChainMessage(asset, amount, chainId);
    }

    /// @inheritdoc IFundsHandler
    function pullFundsFromChain(uint256 amountRay, uint256 chainId) external onlyManager {
        IAccountingChainGateway(_gateway).sendPullFundsFromChainMessage(amountRay, chainId);
    }

    /// @inheritdoc IFundsHandler
    function rescueTokens(address asset, uint256 amount) external onlyManager {
        // TODO: send to treasury? If so can make this public.
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    // Gateway Functions

    /// @inheritdoc IFundsHandler
    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 snapshotTimestamp)
        external
        onlyGateway
    {
        _updateChainBalance(chainId, snapshotBalanceRay, snapshotTimestamp);
    }

    /// @inheritdoc IFundsHandler
    /// @dev Caller must have have transferred funds to this contract
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external onlyGateway {
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    // ////

    function _updateChainBalance(uint256 chainId, uint256 snapshotBalanceRay, uint256 snapshotTimestamp) internal {
        bool chainExists;
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            if (_chainBalances[i].chainId == chainId) {
                chainExists = true;
                if (_chainBalances[i].timestamp < snapshotTimestamp) {
                    _chainBalances[i].timestamp = snapshotTimestamp;
                    _chainBalances[i].amountRay = snapshotBalanceRay;
                }
            }
        }
        if (!chainExists) {
            _chainBalances.push(
                ChainBalanceSnapshot({chainId: chainId, amountRay: snapshotBalanceRay, timestamp: snapshotTimestamp})
            );
        }
    }

    /// @notice Pushes funds to Allocator.
    function _pushFundsToImmediateLiquidity(address asset, uint256 amount) internal {
        IERC20(asset).forceApprove(_allocator, amount);
        IAllocator(_allocator).deposit(asset, amount);
    }

    /// @notice Takes from Allocator and gets ERC20 for further action.
    function _pullFundsFromImmediateLiquidity(address asset, uint256 amount) internal {
        IAllocator(_allocator).withdraw(asset, amount);
    }

    function _verifyAvailableLiquidity(address asset, uint256 amount) internal view {
        require(IAllocator(_allocator).getAssetBalance(asset) >= amount, ErrorsLib.InsufficientLiquidity());
    }
}
