// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {RescuableAssets} from "../common/RescuableAssets.sol";
import {IAccountingChainGateway} from "../interfaces/IAccountingChainGateway.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @title FundsHandler
/// @notice Handles push/pull of funds across the system.
contract FundsHandler is AccessManaged, RescuableAssets, IFundsHandler {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    struct ChainBalanceSnapshot {
        uint256 chainId;
        // Assumes all balances have common denomination.
        uint256 amountRay;
        uint256 nonce;
    }

    ChainBalanceSnapshot[] internal _chainBalances;
    address internal immutable VAULT;
    address internal immutable GATEWAY;
    address internal immutable ALLOCATOR;

    modifier onlyBaseBoostedVault() {
        require(msg.sender == VAULT, NotBaseBoostedVault());
        _;
    }

    modifier onlyGateway() {
        require(msg.sender == GATEWAY, NotGateway());
        _;
    }

    constructor(address accessManager, address basedBoostedVault, address gateway, address allocator)
        AccessManaged(accessManager)
    {
        VAULT = basedBoostedVault;
        GATEWAY = gateway;
        ALLOCATOR = allocator;
    }

    /// @inheritdoc IFundsHandler
    function getAggregatedBalance() external view override returns (uint256) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(ALLOCATOR).getAssetBalances();

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
    function getAssetBalances() external view override returns (AssetBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(ALLOCATOR).getAssetBalances();
        AssetBalance[] memory balances = new AssetBalance[](allocatorAssets.length + _chainBalances.length);
        for (uint16 i = 0; i < allocatorAssets.length; i++) {
            balances[i] = AssetBalance({
                chainId: block.chainid,
                asset: allocatorAssets[i].asset,
                amountRay: allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset)
            });
        }
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            balances[allocatorAssets.length + i] = AssetBalance({
                chainId: _chainBalances[i].chainId, asset: address(0), amountRay: _chainBalances[i].amountRay
            });
        }
        return balances;
    }

    /// @inheritdoc IFundsHandler
    function processDeposit(address asset, uint256 amount) external override onlyBaseBoostedVault {
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    /// @inheritdoc IFundsHandler
    function processWithdrawal(address asset, uint256 amount) external override onlyBaseBoostedVault {
        _verifyAvailableLiquidity(asset, amount);
        _pullFundsFromImmediateLiquidity(asset, amount);
        IERC20(asset).forceApprove(VAULT, amount);
    }

    /// @inheritdoc IFundsHandler
    function pullFromLiquidity(address asset, uint256 amount) external override onlyBaseBoostedVault {
        _pullFundsFromImmediateLiquidity(asset, amount);
        // TODO: Check if we don't need to do increaseApproval here (re-entrancy, multi-withdrawal, etc)
        IERC20(asset).forceApprove(VAULT, amount);
    }

    // Manager Functions

    /// @inheritdoc IFundsHandler
    function pushFundsToChain(address asset, uint256 amount, uint256 chainId) external override restricted {
        _pullFundsFromImmediateLiquidity(asset, amount);
        IERC20(asset).forceApprove(GATEWAY, amount);
        // Increment the chain balance snapshot for the target chain.
        _updateChainBalanceBeforeBridging(chainId, amount.assetDecimalsToRay(asset));
        IAccountingChainGateway(GATEWAY).sendPushFundsToChainMessage(asset, amount, chainId);
    }

    /// @inheritdoc RescuableAssets
    function rescueTokens(address asset, uint256 amount) public override restricted {
        super.rescueTokens(asset, amount);
    }

    // Gateway Functions

    /// @inheritdoc IFundsHandler
    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 chainBalanceSnapshotNonce)
        external
        override
        onlyGateway
    {
        _updateChainBalance(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);
    }

    /// @inheritdoc IFundsHandler
    /// @dev Caller must have have transferred funds to this contract
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external override onlyGateway {
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    // ////

    function _updateChainBalance(uint256 chainId, uint256 snapshotBalanceRay, uint256 chainBalanceSnapshotNonce)
        internal
    {
        bool chainExists;
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            if (_chainBalances[i].chainId == chainId) {
                chainExists = true;
                // Nonces should always be strictly increasing.
                // Use <= for initial snapshot update safety.
                if (_chainBalances[i].nonce < chainBalanceSnapshotNonce) {
                    _chainBalances[i].nonce = chainBalanceSnapshotNonce;
                    _chainBalances[i].amountRay = snapshotBalanceRay;
                }
            }
        }
        if (!chainExists) {
            _chainBalances.push(
                ChainBalanceSnapshot({
                    chainId: chainId, amountRay: snapshotBalanceRay, nonce: chainBalanceSnapshotNonce
                })
            );
        }
    }

    /// @dev This does not update the chain balance snapshot nonce because any potential incoming snapshot data would be
    /// ignored.
    function _updateChainBalanceBeforeBridging(uint256 chainId, uint256 amountToIncrementRay) internal {
        bool chainExists;
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            if (_chainBalances[i].chainId == chainId) {
                chainExists = true;
                _chainBalances[i].amountRay += amountToIncrementRay;
            }
        }
        if (!chainExists) {
            _chainBalances.push(ChainBalanceSnapshot({chainId: chainId, amountRay: amountToIncrementRay, nonce: 0}));
        }
    }

    /// @notice Pushes funds to Allocator.
    function _pushFundsToImmediateLiquidity(address asset, uint256 amount) internal {
        IERC20(asset).forceApprove(ALLOCATOR, amount);
        IAllocator(ALLOCATOR).deposit(asset, amount);
    }

    /// @notice Takes from Allocator and gets ERC20 for further action.
    function _pullFundsFromImmediateLiquidity(address asset, uint256 amount) internal {
        IAllocator(ALLOCATOR).withdraw(asset, amount);
    }

    function _verifyAvailableLiquidity(address asset, uint256 amount) internal view {
        require(IAllocator(ALLOCATOR).getAssetBalance(asset) >= amount, ErrorsLib.InsufficientLiquidity());
    }
}
