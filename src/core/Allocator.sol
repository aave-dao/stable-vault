// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Errors} from "src/types/Errors.sol";

/// @title Allocator
/// @author Aave Labs
/// @notice Allocator contract for managing asset allocations into yield strategies.
/// @dev This contract supports batching of calls using the Multicall contract.
/// @dev Assumptions:
///      - 1 default strategy per asset which serves as the first strategy to deposit to/withdraw from.
///      - multiple allowed strategies per asset which require manual rebalancing
///      - assumes all assets in Allocator share a common denomination
///      - asset amounts are treated in their native decimals
///      - 100% of assets deposited into Allocator belong to the same entity (the Allocator does not track depositors)
contract Allocator is AccessManagedUpgradeable, TransferHelperClient, Multicall, IAllocator {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    address internal immutable DEPOSITOR;
    address internal immutable WITHDRAWER;
    address internal immutable ASSET_REGISTRY;
    address internal immutable PRICE_ORACLE;
    uint8 internal immutable MAX_STRATEGIES_PER_ASSET;

    /// @custom:storage-location erc7201:aave.storage.Allocator
    struct AllocatorStorage {
        mapping(address asset => address strategy) defaultStrategyByAsset;
        mapping(address strategy => StrategyConfig strategyConfig) strategyConfigs;
        // To iterate through all strategies for an asset.
        mapping(address asset => EnumerableSet.AddressSet) assetStrategies;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.Allocator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_ALLOCATOR =
        0x1467d9b012834ae38d27bf9f208a39b5bf5f9a0c5f0adf25ec219f54e4610e00;

    function $storage() private pure returns (AllocatorStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_ALLOCATOR
        }
    }

    modifier onlyDepositor() {
        require(msg.sender == DEPOSITOR, Errors.AddressNotWhitelisted());
        _;
    }

    modifier onlyWithdrawer() {
        require(msg.sender == WITHDRAWER, Errors.AddressNotWhitelisted());
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert Errors.OnlySelf();
        }
        _;
    }

    /// @dev Constructor.
    /// @param assetRegistry The address of the AssetRegistry contract.
    /// @param depositor The address of the depositor to whitelist.
    /// @param withdrawer The address of the withdrawer to whitelist.
    /// @param priceOracle The address of the price oracle contract.
    /// @param transferHelper The address of the contract that helps to minimize the number of transfers across flows.
    /// @param maxStrategiesPerAsset The maximum number of allowed yield strategies per asset.
    constructor(
        address assetRegistry,
        address depositor,
        address withdrawer,
        address priceOracle,
        address transferHelper,
        uint8 maxStrategiesPerAsset
    ) TransferHelperClient(transferHelper) {
        require(assetRegistry != address(0), Errors.ZeroAddress());
        require(depositor != address(0), Errors.ZeroAddress());
        require(withdrawer != address(0), Errors.ZeroAddress());
        require(priceOracle != address(0), Errors.ZeroAddress());
        require(maxStrategiesPerAsset > 0, Errors.InvalidParameter());
        _disableInitializers();
        ASSET_REGISTRY = assetRegistry;
        DEPOSITOR = depositor;
        WITHDRAWER = withdrawer;
        PRICE_ORACLE = priceOracle;
        MAX_STRATEGIES_PER_ASSET = maxStrategiesPerAsset;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __Allocator_init(accessManager);
    }

    function __Allocator_init(address accessManager) internal virtual onlyInitializing {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        __AccessManaged_init(accessManager);
    }

    /// @inheritdoc IAllocator
    function getAssetBalance(address asset) external view returns (uint256) {
        return _getTotalAssetBalance(asset);
    }

    /// @inheritdoc IAllocator
    function getAssetBalanceInStrategy(address strategy) external view returns (uint256) {
        return _getAssetBalanceInStrategy(IERC4626(strategy));
    }

    /// @inheritdoc IAllocator
    function getTrustedAssetBalances() external view override returns (IAllocator.AllocatorBalance[] memory) {
        return _getTrustedAssetBalances();
    }

    /// @inheritdoc IAllocator
    function getDefaultStrategy(address asset) external view override returns (address) {
        return $storage().defaultStrategyByAsset[asset];
    }

    /// @inheritdoc IAllocator
    function getStrategyConfig(address strategy) external view override returns (StrategyConfig memory) {
        return $storage().strategyConfigs[strategy];
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
    function deposit(address asset, uint256 amount) external override onlyDepositor returns (uint256) {
        require(IAssetRegistry(ASSET_REGISTRY).isDepositToAllocatorAllowed(asset), Errors.UnsupportedAsset(asset));
        ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
        uint256 netDepositAmount = amount;
        if ($storage().defaultStrategyByAsset[asset] == address(0)) {
            emit AssetLeftIdle(asset, amount);
            return amount;
        }
        netDepositAmount =
            _depositToStrategy({asset: asset, amount: amount, strategy: $storage().defaultStrategyByAsset[asset]});
        return Math.min(netDepositAmount, amount);
    }

    /// @inheritdoc IAllocator
    function depositAllowIdle(address asset, uint256 amount) external override onlyDepositor {
        require(IAssetRegistry(ASSET_REGISTRY).isDepositToAllocatorAllowed(asset), Errors.UnsupportedAsset(asset));
        ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
        if ($storage().defaultStrategyByAsset[asset] == address(0)) {
            emit AssetLeftIdle(asset, amount);
            return;
        }
        try this.tryDepositToStrategy(asset, amount, $storage().defaultStrategyByAsset[asset]) {}
        catch {
            emit AssetLeftIdle(asset, amount);
            emit StrategyDepositFailed($storage().defaultStrategyByAsset[asset], amount);
        }
    }

    /// @inheritdoc IAllocator
    function withdraw(address asset, uint256 amount) external override onlyWithdrawer {
        require(amount > 0, Errors.ZeroAmount());
        _validateCanWithdraw(asset);

        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        if (idleBalance < amount) {
            // Consume from idle balance first
            uint256 amountRemaining = amount - idleBalance;

            // Consume from default strategy
            // Wrap in a try-catch to avoid impact to searching other strategies
            try this.tryWithdrawFromStrategy(asset, amountRemaining, $storage().defaultStrategyByAsset[asset]) returns (
                uint256 withdrawn
            ) {
                amountRemaining -= withdrawn;
            } catch {
                emit StrategyWithdrawalFailed($storage().defaultStrategyByAsset[asset], asset, amountRemaining);
            }

            // If necessary, pull from remaining strategies
            uint256 length = $storage().assetStrategies[asset].length();
            for (uint256 i = 0; amountRemaining > 0 && i < length; i++) {
                address strategy = $storage().assetStrategies[asset].at(i);
                if (strategy != $storage().defaultStrategyByAsset[asset]) {
                    try this.tryWithdrawFromStrategy(asset, amountRemaining, strategy) returns (uint256 withdrawn) {
                        amountRemaining -= withdrawn;
                    } catch {
                        emit StrategyWithdrawalFailed(strategy, asset, amountRemaining);
                    }
                }
            }
            require(amountRemaining == 0, Errors.InsufficientFunds());
        }
        _transferToTransferHelper(asset, amount);
    }

    /// @dev Implements the external and onlySelf modifier because this function is intended to be wrapped in a
    /// try-catch.
    function tryDepositToStrategy(address asset, uint256 amount, address strategy) external onlySelf {
        _depositToStrategy({asset: asset, amount: amount, strategy: strategy});
    }

    /// @dev Implements the external and onlySelf modifier because this function is intended to be wrapped in a
    /// try-catch.
    /// @dev Avoids impact to searching other strategies if withdrawal from a previously searched strategy
    /// fails.
    /// @dev The `amount` param is not taking into account nor being aware of the `strategy`'s liquidity.
    function tryWithdrawFromStrategy(address asset, uint256 amount, address strategy)
        external
        onlySelf
        returns (uint256)
    {
        uint256 withdrawnAmount;
        // Use maxWithdraw to account for withdrawal limits or timelocks.
        uint256 maxWithdrawable = IERC4626(strategy).maxWithdraw(address(this));
        if (maxWithdrawable == 0) {
            // Some ERC-4626 implementations may return 0 for `maxWithdraw` to adhere to the spec rule of not reverting.
            // Fallback to querying the balance that may not account for withdrawal limits or timelocks.
            withdrawnAmount = Math.min(amount, _getAssetBalanceInStrategy(IERC4626(strategy)));
        } else {
            withdrawnAmount = Math.min(amount, maxWithdrawable);
        }
        if (withdrawnAmount != 0) {
            _withdrawFromStrategy(asset, withdrawnAmount, address(this), strategy);
        }
        return withdrawnAmount;
    }

    //////////////////////////////////////////// MANAGER FUNCTIONS /////////////////////////////////////////////////////

    /// @inheritdoc IAllocator
    function rebalance(RebalanceParams[] memory params) external virtual override restricted {
        for (uint256 i = 0; i < params.length; i++) {
            _rebalance(params[i]);
        }
    }

    /// @inheritdoc IAllocator
    function addStrategy(address asset, address strategy, uint8 maxSlippageAmount) external override restricted {
        _addStrategy(asset, strategy, maxSlippageAmount);
    }

    /// @inheritdoc IAllocator
    function removeStrategy(address strategy) external override restricted {
        _removeStrategy(strategy);
    }

    /// @inheritdoc IAllocator
    function setDefaultStrategy(address asset, address strategy) external override restricted {
        if (strategy != address(0)) {
            // Strategy must be allowed to be set as the default strategy for the asset
            require(strategy != $storage().defaultStrategyByAsset[asset], DefaultStrategy(strategy));
            require(_isStrategySupportedForAsset({strategy: strategy, asset: asset}), Errors.AddressNotWhitelisted());
            require($storage().strategyConfigs[strategy].depositAllowed, DepositsToStrategyDisabled(strategy));
        }
        $storage().defaultStrategyByAsset[asset] = strategy;
        emit DefaultStrategySet(asset, strategy);
    }

    /// @inheritdoc IAllocator
    function disableDepositsToStrategy(address strategy) external override restricted {
        require(_isStrategySupported(strategy), Errors.AddressNotWhitelisted());
        $storage().strategyConfigs[strategy].depositAllowed = false;
        emit StrategyDepositsToggled(strategy, false);
    }

    /// @inheritdoc IAllocator
    function enableDepositsToStrategy(address strategy) external override restricted {
        require(_isStrategySupported(strategy), Errors.AddressNotWhitelisted());
        $storage().strategyConfigs[strategy].depositAllowed = true;
        emit StrategyDepositsToggled(strategy, true);
    }

    ////////////////////////////////////////////////// INTERNAL ////////////////////////////////////////////////////////

    function _rebalance(RebalanceParams memory rebalanceParams) internal {
        uint256 i;

        // Execute all deallocations in the order specified by the deallocations array.
        for (i = 0; i < rebalanceParams.deallocations.length; i++) {
            _deallocate(rebalanceParams.deallocations[i]);
        }

        // Execute all swaps in the order specified by the swaps array.
        for (i = 0; i < rebalanceParams.swaps.length; i++) {
            _swap(rebalanceParams.swaps[i]);
        }

        // Execute all allocations in the order specified by the allocations array.
        for (i = 0; i < rebalanceParams.allocations.length; i++) {
            _allocate(rebalanceParams.allocations[i]);
        }
    }

    function _deallocate(DeallocationParams memory deallocation) internal {
        require(
            _isStrategySupportedForAsset({strategy: deallocation.strategy, asset: deallocation.asset}),
            Errors.AddressNotWhitelisted()
        );
        if (deallocation.amount == 0) {
            _redeemAllFromStrategy(deallocation.asset, deallocation.strategy);
        } else {
            _withdrawFromStrategy(deallocation.asset, deallocation.amount, address(this), deallocation.strategy);
        }
    }

    function _swap(SwapParams memory swap) internal {
        require(IAssetRegistry(ASSET_REGISTRY).isSwapInputAllowed(swap.assetIn), Errors.UnsupportedAsset(swap.assetIn));
        require(
            IAssetRegistry(ASSET_REGISTRY).isSwapOutputAllowed(swap.assetOut), Errors.UnsupportedAsset(swap.assetOut)
        );
        _validateSwapAmountIn(swap.assetIn, swap.amountIn, swap.assetOut);
        IPriceOracle(PRICE_ORACLE).validatePrice(swap.assetOut);

        // Transfer assetIn to the swapper
        IERC20(swap.assetIn).safeTransfer(swap.swapper, swap.amountIn);

        // Execute the swap and require 1:1 conversion
        uint256 amountOut = ISwapper(swap.swapper).executeSwap(swap.assetIn, swap.assetOut, swap.amountIn, swap.data);
        require(
            amountOut >= swap.amountIn.convertAssetDecimals(swap.assetIn, swap.assetOut), Errors.InsufficientAmountOut()
        );

        // Pull the `assetOut` from the Swapper to the Allocator
        IERC20(swap.assetOut).safeTransferFrom(swap.swapper, address(this), amountOut);

        emit AssetsSwapped(swap.assetIn, swap.assetOut, swap.amountIn, amountOut);
    }

    function _validateCanWithdraw(address asset) internal view {
        // Ensure that the asset is registered in the AssetRegistry.
        // This helps avoid withdrawal of an asset that is held in the Allocator that is not intended to be withdrawn by
        // users. The Allocator may hold assets it received accidentally or from rewards earned from supplying to
        // strategies.
        require(IAssetRegistry(ASSET_REGISTRY).isAssetRegistered(asset), Errors.UnsupportedAsset(asset));
        // Ensure that the asset being withdrawn is not a strategy share that may be held by the Allocator.
        require(!$storage().strategyConfigs[asset].isRegistered, Errors.UnsupportedAsset(asset));
    }

    /// @notice Validates that dust from `amountIn` would not be truncated when converting to a value of `assetOut`.
    /// @dev Dust from `amountIn` can be leaked out of the system if the `assetOut` has fewer decimals than `assetIn`.
    /// @dev When checking for 1:1 swap between `assetIn` and `assetOut`, we truncate `amountIn` to have number of
    /// decimals for `assetOut`.
    /// @dev Dust that is input into a swap would be unaccounted for and could be lost.
    function _validateSwapAmountIn(address assetIn, uint256 amountIn, address assetOut) internal view {
        uint256 inputDecimals = AssetLib.getDecimals(assetIn);
        uint256 outputDecimals = AssetLib.getDecimals(assetOut);
        if (inputDecimals > outputDecimals) {
            // Check there is no remainder when truncating `amountIn` to `assetOut` decimals.
            require(amountIn % 10 ** (inputDecimals - outputDecimals) == 0, Errors.InvalidAmount());
        }
    }

    function _allocate(AllocationParams memory allocation) internal {
        require(
            _isStrategySupportedForAsset({strategy: allocation.strategy, asset: allocation.asset}),
            Errors.AddressNotWhitelisted()
        );
        uint256 amountToAllocate;
        if (allocation.amount == 0) {
            amountToAllocate = IERC20(allocation.asset).balanceOf(address(this));
        } else {
            amountToAllocate = allocation.amount;
        }
        _depositToStrategy({asset: allocation.asset, amount: amountToAllocate, strategy: allocation.strategy});
    }

    /// @dev Intended to be the lowest level function used to withdraw from a strategy.
    function _withdrawFromStrategy(address asset, uint256 amount, address receiver, address strategy) internal {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC4626(strategy).withdraw({assets: amount, receiver: receiver, owner: address(this)});
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        require(balanceAfter - balanceBefore >= amount, Errors.InsufficientAmountOut());
        emit AssetDeallocated(asset, strategy, amount);
    }

    function _redeemAllFromStrategy(address asset, address strategy) internal returns (uint256) {
        uint256 shares = IERC4626(strategy).balanceOf(address(this));
        if (shares == 0) {
            // Gracefully return 0 if the strategy has no shares to avoid disrupting a multi-deallocate rebalance.
            return 0;
        }
        uint256 amount = IERC4626(strategy).redeem({shares: shares, receiver: address(this), owner: address(this)});
        emit AssetDeallocated(asset, strategy, amount);
        return amount;
    }

    /// @dev Intended to be the lowest level function used to deposit into a strategy.
    function _depositToStrategy(address asset, uint256 amount, address strategy) internal returns (uint256) {
        require(amount > 0, Errors.ZeroAmount());
        require($storage().strategyConfigs[strategy].depositAllowed, DepositsToStrategyDisabled(strategy));
        IERC20(asset).forceApprove(strategy, amount);

        uint256 balanceBefore = _getAssetBalanceInStrategy(IERC4626(strategy));

        (bool callSucceeded,) = strategy.call(abi.encodeCall(IERC4626.deposit, (amount, address(this))));
        require(callSucceeded, DepositIntoStrategyFailed(strategy));

        uint256 netDepositAmount = _getAssetBalanceInStrategy(IERC4626(strategy)) - balanceBefore;
        require(
            netDepositAmount >= amount
                || amount - netDepositAmount <= $storage().strategyConfigs[strategy].maxSlippageAmount,
            Errors.InsufficientAmountOut()
        );
        emit AssetAllocated(asset, strategy, amount, netDepositAmount);
        return netDepositAmount;
    }

    /// @dev Returns balances grouped by asset.
    function _getTrustedAssetBalances() internal view returns (IAllocator.AllocatorBalance[] memory) {
        address[] memory assets = IAssetRegistry(ASSET_REGISTRY).getTrustedAssets();
        IAllocator.AllocatorBalance[] memory allocatedAssets = new IAllocator.AllocatorBalance[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            allocatedAssets[i] = IAllocator.AllocatorBalance({asset: asset, amount: _getTotalAssetBalance(asset)});
        }
        return allocatedAssets;
    }

    function _getTotalAssetBalance(address asset) internal view returns (uint256) {
        uint256 balance = 0;
        uint256 strategiesLength = $storage().assetStrategies[asset].length();
        for (uint256 i = 0; i < strategiesLength; i++) {
            balance += _getAssetBalanceInStrategy(IERC4626($storage().assetStrategies[asset].at(i)));
        }
        balance += IERC20(asset).balanceOf(address(this));
        return balance;
    }

    function _getAssetBalanceInStrategy(IERC4626 strategy) internal view returns (uint256) {
        uint256 amount = strategy.previewRedeem(strategy.balanceOf(address(this)));
        return amount;
    }

    function _isStrategySupportedForAsset(address strategy, address asset) internal view returns (bool) {
        return $storage().strategyConfigs[strategy].asset == asset;
    }

    function _isStrategySupported(address strategy) internal view returns (bool) {
        return $storage().strategyConfigs[strategy].asset != address(0);
    }

    function _addStrategy(address asset, address strategy, uint8 maxSlippageAmount) internal {
        require(!_isStrategySupported(strategy), Errors.AddressAlreadyWhitelisted());
        require(IAssetRegistry(ASSET_REGISTRY).isAssetRegistered(asset), Errors.InvalidAsset(asset));
        require(asset == IERC4626(strategy).asset(), Errors.InvalidAsset(asset));

        $storage().strategyConfigs[strategy] = StrategyConfig({
            asset: asset, maxSlippageAmount: maxSlippageAmount, isRegistered: true, depositAllowed: true
        });
        $storage().assetStrategies[asset].add(strategy);

        require(
            $storage().assetStrategies[asset].length() <= MAX_STRATEGIES_PER_ASSET, IAllocator.TooManyStrategies(asset)
        );

        emit StrategyAdded(asset, strategy, maxSlippageAmount);
    }

    function _removeStrategy(address strategy) internal {
        require(_isStrategySupported(strategy), Errors.AddressNotWhitelisted());
        require($storage().defaultStrategyByAsset[IERC4626(strategy).asset()] != strategy, DefaultStrategy(strategy));
        // This can get blocked if assets are deposited into the strategy on behalf of the Allocator.
        // This function is intended to clear storage, so if it gets DoS'd then the consequences are consumed storage.
        // This function does not allow removing a strategy if balance > 0 to avoid accidentally disregarding asset
        // balances when fetched by consumers.
        // This function does not force max withdraw from a strategy to avoid unintended behavior e.g. incurring
        // slippage.
        require(IERC4626(strategy).balanceOf(address(this)) == 0, StrategyStillHasFunds(strategy));
        address asset = $storage().strategyConfigs[strategy].asset;

        $storage().assetStrategies[asset].remove(strategy);
        delete $storage().strategyConfigs[strategy];
        emit StrategyRemoved(asset, strategy);
    }
}
