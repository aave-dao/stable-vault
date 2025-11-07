// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAllocator} from "../interfaces/IAllocator.sol";
import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";

import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @dev Assumptions:
///      - 1 default strategy per asset
///      - multiple allowed strategy per asset which require manual reallocation
///      - multiple assets per allocator with a common denomination
///      - assets are in their native decimals
///      - 100% of assets deposited into Allocator belong to the same entity (the Allocator does not track depositors)
/// @dev Deals with assets in their native decimals.
contract Allocator is AccessManagedUpgradeable, IAllocator {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    struct StrategyData {
        address asset;
        uint32 indexInAssetStrategies;
        uint32 indexInAllStrategies;
    }

    address internal immutable DEPOSITOR;
    address internal immutable WITHDRAWER;
    address internal immutable ASSET_REGISTRY;

    // Yield strategies
    // - _defaultStrategyByAsset: The default strategy for an asset which funds are deposited into and withdrawn from.
    // - _assetStrategies: Entire set of allowed strategies for an asset which funds can be reallocated to/from
    mapping(address asset => address strategy) internal _defaultStrategyByAsset;
    mapping(address strategy => StrategyData strategyData) internal _strategyData;
    // To iterate through all strategies for an asset.
    mapping(address asset => address[]) internal _assetStrategies;
    // To allow O(1) lookup to see if asset should be added/removed from _assetsWithSupportedStrategies.
    mapping(address asset => uint256 strategiesCount) internal _assetStrategyCount;
    // To iterate through all strategies.
    address[] internal _allStrategies;
    // To iterate through all assets with supported strategies and collect their balances.
    address[] internal _assetsWithSupportedStrategies;

    modifier onlyDepositor() {
        require(msg.sender == DEPOSITOR, ErrorsLib.AddressNotWhitelisted());
        _;
    }

    modifier onlyWithdrawer() {
        require(msg.sender == WITHDRAWER, ErrorsLib.AddressNotWhitelisted());
        _;
    }

    /// @dev Constructor.
    /// @param assetRegistry The address of the AssetRegistry contract.
    /// @param depositor The address of the depositor to whitelist.
    /// @param withdrawer The address of the withdrawer to whitelist.
    constructor(address assetRegistry, address depositor, address withdrawer) {
        _disableInitializers();
        DEPOSITOR = depositor;
        WITHDRAWER = withdrawer;
        ASSET_REGISTRY = assetRegistry;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __Allocator_init(accessManager);
    }

    function __Allocator_init(address accessManager) internal virtual onlyInitializing {
        __AccessManaged_init(accessManager);
    }

    function getAssetBalance(address asset) external view returns (uint256) {
        return _getTotalAssetBalance(asset);
    }

    function getAssetBalanceInStrategy(address strategy) external view returns (uint256) {
        return _getAssetBalanceInStrategy(IERC4626(strategy));
    }

    /// @inheritdoc IAllocator
    function getAssetBalances() external view override returns (IAllocator.AllocatorBalance[] memory) {
        return _getAssetBalances();
    }

    /// @inheritdoc IAllocator
    function getDefaultStrategy(address asset) external view override returns (address) {
        return _defaultStrategyByAsset[asset];
    }

    /// @inheritdoc IAllocator
    function isStrategySupportedForAsset(address asset, address strategy) external view override returns (bool) {
        return _isStrategySupportedForAsset({strategy: strategy, asset: asset});
    }

    /// @inheritdoc IAllocator
    function isStrategySupported(address strategy) external view override returns (bool) {
        return _isStrategySupported(strategy);
    }

    /// @inheritdoc IAllocator
    function deposit(address asset, uint256 amount) external override onlyDepositor {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        bool callSucceeded = _deposit({asset: asset, amount: amount});
        if (!callSucceeded) {
            emit StrategyDepositFailed(_defaultStrategyByAsset[asset], amount);
        }
    }

    /// @inheritdoc IAllocator
    function withdraw(address asset, uint256 amount) external override onlyWithdrawer {
        require(amount > 0, ErrorsLib.ZeroAmount());
        require(
            IAssetRegistry(ASSET_REGISTRY).isAllowedToWithdrawFromAllocator(asset), ErrorsLib.UnsupportedAsset(asset)
        );

        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        if (idleBalance < amount) {
            // Consume from idle balance first
            uint256 amountRemaining = amount - idleBalance;

            // Consume from default strategy
            amountRemaining -= _withdrawFromStrategy(asset, amountRemaining, _defaultStrategyByAsset[asset]);

            // If necessary, pull from remaining strategies
            for (uint256 i = 0; amountRemaining > 0 && i < _assetStrategies[asset].length; i++) {
                address strategy = _assetStrategies[asset][i];
                if (strategy != _defaultStrategyByAsset[asset]) {
                    amountRemaining -= _withdrawFromStrategy(asset, amountRemaining, strategy);
                }
            }
        }
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    //////////////////////////////////////////// MANAGER FUNCTIONS /////////////////////////////////////////////////////

    /// @inheritdoc IAllocator
    function deallocate(address asset, uint256 assetsAmount, address strategy)
        external
        override
        restricted
        returns (uint256)
    {
        require(IERC4626(strategy).asset() == asset, ErrorsLib.InvalidAsset(asset));
        if (assetsAmount == 0) {
            // If zero is passed, we withdraw the max amount using shares.
            uint256 maxShares = IERC4626(strategy).maxRedeem(address(this));
            uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
            uint256 assetsWithdrawn = _deallocateShares(strategy, asset, maxShares, address(this));
            uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
            require(balanceAfter - balanceBefore == assetsWithdrawn, ErrorsLib.InsufficientAmountOut());
            return maxShares;
        } else {
            uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
            uint256 sharesBurned = _deallocate(strategy, asset, assetsAmount, address(this));
            uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
            require(balanceAfter - balanceBefore == assetsAmount, ErrorsLib.InsufficientAmountOut());
            return sharesBurned;
        }
    }

    /// @inheritdoc IAllocator
    function depositIdleFunds(address asset) external override restricted {
        uint256 amount = IERC20(asset).balanceOf(address(this));
        bool callSucceeded = _deposit({asset: asset, amount: amount});
        require(callSucceeded, IAllocator.FailedToDepositIntoStrategy());
    }

    /// @inheritdoc IAllocator
    function rebalance(CrossAssetRebalanceParams memory params) external override restricted {
        for (uint256 i = 0; i < params.swaps.length; i++) {
            address assetIn = params.swaps[i].assetIn;
            require(
                IAssetRegistry(ASSET_REGISTRY).isAllowedSwapInputToken(assetIn), ErrorsLib.UnsupportedAsset(assetIn)
            );
            address assetOut = params.swaps[i].assetOut;
            require(
                IAssetRegistry(ASSET_REGISTRY).isAllowedSwapOutputToken(assetOut)
                    && IAssetRegistry(ASSET_REGISTRY).isAllowedToDepositIntoAllocator(assetOut),
                ErrorsLib.UnsupportedAsset(assetOut)
            );
            uint256 amountIn = params.swaps[i].amountIn;
            uint256 idleBalance = IERC20(assetIn).balanceOf(address(this));
            if (idleBalance < amountIn) {
                // Withdraw assets from strategy to this contract
                IERC4626(_defaultStrategyByAsset[assetIn])
                    .withdraw(amountIn - idleBalance, address(this), address(this));
            }
            address swapper = params.swaps[i].swapper;
            // Transfer assetIn to the swapper
            IERC20(params.swaps[i].assetIn).safeTransfer(swapper, amountIn);
            // Execute the swap and require 1:1 conversion
            uint256 assetOutAmount = ISwapper(swapper)
                .executeSwap(params.swaps[i].assetIn, params.swaps[i].assetOut, amountIn, params.swaps[i].swapData);
            require(
                assetOutAmount >= amountIn.convertAssetDecimals(assetIn, assetOut), ErrorsLib.InsufficientAmountOut()
            );

            // Pull the `assetOut` from the Swapper to the Allocator
            IERC20(params.swaps[i].assetOut).safeTransferFrom(swapper, address(this), assetOutAmount);

            // Deposit the assetOut into the strategy
            IERC20(params.swaps[i].assetOut).forceApprove(address(_defaultStrategyByAsset[assetOut]), assetOutAmount);
            IERC4626(_defaultStrategyByAsset[assetOut]).deposit(assetOutAmount, address(this));
        }
    }

    // TODO: Consider consolidating `rebalance` and `reallocate` functions into a single function.

    /// @inheritdoc IAllocator
    function reallocate(address asset, uint256 amount, address fromStrategy, address toStrategy)
        external
        override
        restricted
    {
        require(_isStrategySupportedForAsset({strategy: fromStrategy, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        require(_isStrategySupportedForAsset({strategy: toStrategy, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        // Pull the asset from the fromStrategy to the Allocator
        _deallocate(fromStrategy, asset, amount, address(this));
        // Push the asset to the toStrategy
        _deposit(asset, amount);
    }

    /// @inheritdoc IAllocator
    function addStrategy(address asset, address strategy) external override restricted {
        _addStrategy(asset, strategy);
    }

    /// @inheritdoc IAllocator
    function removeStrategy(address strategy) external override restricted {
        _removeStrategy(strategy);
    }

    /// @inheritdoc IAllocator
    function setDefaultStrategy(address asset, address strategy) external restricted {
        // Strategy must be allowed to be set as the default strategy for the asset
        require(_defaultStrategyByAsset[asset] != strategy, ErrorsLib.AddressAlreadyWhitelisted());
        require(_isStrategySupportedForAsset({strategy: strategy, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        _defaultStrategyByAsset[asset] = strategy;
        emit DefaultStrategySet(asset, strategy);
    }

    ////////////////////////////////////////////////// INTERNAL ////////////////////////////////////////////////////////

    function _deallocate(address strategy, address asset, uint256 amount, address receiver) internal returns (uint256) {
        uint256 burnedShares = IERC4626(strategy).withdraw({assets: amount, receiver: receiver, owner: address(this)});
        emit AssetDeallocated(asset, strategy, amount, burnedShares);
        return burnedShares;
    }

    function _deallocateShares(address strategy, address asset, uint256 sharesAmount, address receiver)
        internal
        returns (uint256)
    {
        uint256 assetsWithdrawn =
            IERC4626(strategy).redeem({shares: sharesAmount, receiver: receiver, owner: address(this)});
        emit AssetDeallocated(asset, strategy, assetsWithdrawn, sharesAmount);
        return assetsWithdrawn;
    }

    function _deposit(address asset, uint256 amount) internal returns (bool) {
        require(amount > 0, ErrorsLib.ZeroAmount());
        require(
            IAssetRegistry(ASSET_REGISTRY).isAllowedToDepositIntoAllocator(asset), ErrorsLib.UnsupportedAsset(asset)
        );
        address strategy = _defaultStrategyByAsset[asset];
        if (strategy == address(0)) {
            // A strategy for this asset is not set, so the funds stay idle in the Allocator.
            return true;
        }
        IERC20(asset).forceApprove(strategy, amount);
        (bool callSucceeded,) = strategy.call(abi.encodeCall(IERC4626.deposit, (amount, address(this))));
        return callSucceeded;
    }

    function _withdrawFromStrategy(address asset, uint256 amount, address strategy) internal returns (uint256) {
        // TODO: review if the following require is actually needed
        require(_isStrategySupportedForAsset({strategy: strategy, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        uint256 withdrawnAmount;
        uint256 balanceInStrategy = _getAssetBalanceInStrategy(IERC4626(strategy));
        if (balanceInStrategy > 0) {
            withdrawnAmount = balanceInStrategy > amount ? amount : balanceInStrategy;
            _deallocate(strategy, asset, withdrawnAmount, address(this));
        }
        return withdrawnAmount;
    }

    /// @dev Returns balances grouped by asset.
    function _getAssetBalances() internal view returns (IAllocator.AllocatorBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatedAssets =
            new IAllocator.AllocatorBalance[](_assetsWithSupportedStrategies.length);
        for (uint256 i = 0; i < _assetsWithSupportedStrategies.length; i++) {
            address asset = _assetsWithSupportedStrategies[i];
            allocatedAssets[i] = IAllocator.AllocatorBalance({asset: asset, amount: _getTotalAssetBalance(asset)});
        }
        return allocatedAssets;
    }

    function _getTotalAssetBalance(address asset) internal view returns (uint256) {
        uint256 balance = 0;
        for (uint256 i = 0; i < _assetStrategies[asset].length; i++) {
            balance += _getAssetBalanceInStrategy(IERC4626(_assetStrategies[asset][i]));
        }
        balance += IERC20(asset).balanceOf(address(this));
        return balance;
    }

    function _getAssetBalanceInStrategy(IERC4626 strategy) internal view returns (uint256) {
        uint256 amount = strategy.previewRedeem(strategy.balanceOf(address(this)));
        return amount;
    }

    function _isStrategySupportedForAsset(address strategy, address asset) internal view returns (bool) {
        return _strategyData[strategy].asset == asset;
    }

    function _isStrategySupported(address strategy) internal view returns (bool) {
        return _strategyData[strategy].asset != address(0);
    }

    function _addStrategy(address asset, address strategy) internal {
        require(!_isStrategySupported(strategy), ErrorsLib.AddressAlreadyWhitelisted());
        require(IERC4626(strategy).asset() == asset, ErrorsLib.InvalidAsset(asset));
        _assetStrategies[asset].push(strategy);
        _allStrategies.push(strategy);
        _strategyData[strategy] = StrategyData({
            asset: asset,
            indexInAssetStrategies: uint32(_assetStrategies[asset].length - 1),
            indexInAllStrategies: uint32(_allStrategies.length - 1)
        });

        // Add asset to _assetsWithSupportedStrategies if it is not already in the list
        if (_assetStrategyCount[asset] == 0) {
            _assetsWithSupportedStrategies.push(asset);
        }
        _assetStrategyCount[asset]++;

        emit StrategyAdded(asset, strategy);
    }

    function _removeStrategy(address strategy) internal {
        StrategyData memory strategyData = _strategyData[strategy];
        require(_isStrategySupported(strategy), ErrorsLib.AddressNotWhitelisted());
        if (strategy == _defaultStrategyByAsset[strategyData.asset]) {
            // Unset the default strategy for the asset - deposits will not flow to this strategy.
            // If the default strategy is removed, another one should be set as the default for withdrawals.
            delete _defaultStrategyByAsset[strategyData.asset];
            emit DefaultStrategySet(strategyData.asset, address(0));
        }

        // Remove strategy from _assetStrategies
        if (_assetStrategies[strategyData.asset].length > 1) {
            uint32 index = strategyData.indexInAssetStrategies;
            _assetStrategies[strategyData.asset][index] =
                _assetStrategies[strategyData.asset][_assetStrategies[strategyData.asset].length - 1];
            _strategyData[strategy].indexInAssetStrategies = index;
        }
        _assetStrategies[strategyData.asset].pop();

        // Remove strategy from _allStrategies
        if (_allStrategies.length > 1) {
            uint32 indexInAllStrategies = strategyData.indexInAllStrategies;
            _allStrategies[indexInAllStrategies] = _allStrategies[_allStrategies.length - 1];
            _strategyData[strategy].indexInAllStrategies = indexInAllStrategies;
        }
        _allStrategies.pop();

        // Update storage that tracks assets with supported strategies
        _assetStrategyCount[strategyData.asset]--;
        if (_assetStrategyCount[strategyData.asset] == 0) {
            // Remove asset from _assetsWithSupportedStrategies
            for (uint256 i = 0; i < _assetsWithSupportedStrategies.length; i++) {
                if (_assetsWithSupportedStrategies[i] == strategyData.asset) {
                    _assetsWithSupportedStrategies[i] =
                        _assetsWithSupportedStrategies[_assetsWithSupportedStrategies.length - 1];
                    _assetsWithSupportedStrategies.pop();
                    break;
                }
            }
        }

        delete _strategyData[strategy];
        emit StrategyRemoved(strategyData.asset, strategy);
    }
}
