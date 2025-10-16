// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFundsHandler} from "../interfaces/IFundsHandler.sol";

import {IAccountingChainGateway} from "../interfaces/IAccountingChainGateway.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

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

    // TODO: Add to the interface
    function getWithdrawalRequest(uint256 withdrawalRequestId) external view returns (WithdrawalRequest memory) {
        return _withdrawalRequests[withdrawalRequestId];
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

    function processWithdrawalExecution(
        uint256 withdrawalRequestId,
        bytes calldata /* data */
    )
        external
        override
        onlyBaseBoostedVault
        returns (address, uint256, address, bytes memory)
    {
        WithdrawalRequest storage request = _withdrawalRequests[withdrawalRequestId];
        _verifyAvailableLiquidity(
            request.preferredAsset, request.amountRequested.rayToAssetDecimals(request.preferredAsset)
        );
        (address asset, uint256 amount, address recipient) = _executeWithdrawal(withdrawalRequestId, request);
        return (asset, amount, recipient, "");
    }

    /// @inheritdoc IFundsHandler
    function pullFromLiquidity(address asset, uint256 amount) external onlyBaseBoostedVault {
        _pullFundsFromImmediateLiquidity(asset, amount);
        // TODO: Check if we don't need to do increaseApproval here (re-entrancy, multi-withdrawal, etc)
        IERC20(asset).forceApprove(_basedBoostedVault, amount);
    }

    function rescueTokens(address asset, uint256 amount) external onlyManager {
        _pullFundsFromImmediateLiquidity(asset, amount);
        // TODO: send to treasury?
        IERC20(asset).transfer(msg.sender, amount);
    }

    function _executeWithdrawal(uint256 withdrawalRequestId, WithdrawalRequest storage request)
        internal
        returns (address, uint256, address)
    {
        address asset = request.preferredAsset;
        uint256 amount = request.amountRequested.rayToAssetDecimals(asset);
        address recipient = request.recipient;
        delete _withdrawalRequests[withdrawalRequestId];
        _pullFundsFromImmediateLiquidity(asset, amount);
        IERC20(asset).forceApprove(_basedBoostedVault, amount);
        return (asset, amount, recipient);
    }

    function _verifyAvailableLiquidity(address asset, uint256 amount) internal view {
        require(IAllocator(_allocator).getAssetBalance(asset) >= amount, ErrorsLib.InsufficientLiquidity());
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
        IERC20(asset).forceApprove(_gateway, amount);
        IAccountingChainGateway(_gateway).sendPushFundsToChainMessage(asset, amount, chainId);
    }

    function pullFundsFromChain(uint256 amount, uint256 chainId) external onlyManager {
        IAccountingChainGateway(_gateway).sendPullFundsFromChainMessage(amount, chainId);
    }

    // Gateway Functions

    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalance, uint256 snapshotTimestamp)
        external
        onlyGateway
    {
        _updateChainBalance(chainId, snapshotBalance, snapshotTimestamp);
    }

    /// @dev Caller must have have transferred funds to this contract
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external onlyGateway {
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
