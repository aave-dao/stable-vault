// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";

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

    /// @notice The data for a strategy.
    /// @param asset Address of the asset that the strategy is for.
    /// @param indexInAssetStrategies Index of the strategy in the asset's strategies array.
    /// @param indexInAllStrategies Index of the strategy in the all strategies array.
    struct StrategyData {
        address asset;
        uint32 indexInAssetStrategies;
        uint32 indexInAllStrategies;
    }

    address internal immutable DEPOSITOR;
    address internal immutable WITHDRAWER;
    address internal immutable ASSET_REGISTRY;

    /// @custom:storage-location erc7201:aave.storage.Allocator
    struct AllocatorStorage {
        mapping(address asset => address strategy) defaultStrategyByAsset;
        mapping(address strategy => StrategyData strategyData) strategyData;
        // To iterate through all strategies for an asset.
        mapping(address asset => address[]) assetStrategies;
        // To allow O(1) lookup to see if asset should be added/removed from $storage().assetsWithSupportedStrategies.
        mapping(address asset => uint256 strategiesCount) assetStrategyCount;
        // To iterate through all strategies.
        address[] allStrategies;
        // List of all supported assets that have at least one strategy.
        address[] assetsWithSupportedStrategies;
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
    constructor(address assetRegistry, address depositor, address withdrawer, address transferHelper)
        TransferHelperClient(transferHelper)
    {
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
        return $storage().defaultStrategyByAsset[asset];
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
        ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
        _depositToStrategy({asset: asset, amount: amount, strategy: $storage().defaultStrategyByAsset[asset]});
    }

    /// @inheritdoc IAllocator
    function withdraw(address asset, uint256 amount) external override onlyWithdrawer {
        require(amount > 0, ErrorsLib.ZeroAmount());
        require(
            IAssetRegistry(ASSET_REGISTRY).isWithdrawalFromAllocatorAllowed(asset), ErrorsLib.UnsupportedAsset(asset)
        );

        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        if (idleBalance < amount) {
            // Consume from idle balance first
            uint256 amountRemaining = amount - idleBalance;

            // Consume from default strategy
            amountRemaining -= _tryWithdrawFromStrategy(
                asset, amountRemaining, $storage().defaultStrategyByAsset[asset]
            );

            // If necessary, pull from remaining strategies
            for (uint256 i = 0; amountRemaining > 0 && i < $storage().assetStrategies[asset].length; i++) {
                address strategy = $storage().assetStrategies[asset][i];
                if (strategy != $storage().defaultStrategyByAsset[asset]) {
                    amountRemaining -= _tryWithdrawFromStrategy(asset, amountRemaining, strategy);
                }
            }
        }
        _transferToTransferHelper(asset, amount);
    }

    //////////////////////////////////////////// MANAGER FUNCTIONS /////////////////////////////////////////////////////

    /// @inheritdoc IAllocator
    function rebalance(RebalanceParams[] memory params) external override restricted {
        for (uint256 i = 0; i < params.length; i++) {
            _rebalance(params[i]);
        }
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
    function setDefaultStrategy(address asset, address strategy) external override restricted {
        // Strategy must be allowed to be set as the default strategy for the asset
        require(strategy != $storage().defaultStrategyByAsset[asset], ErrorsLib.AddressAlreadyWhitelisted());
        require(_isStrategySupportedForAsset({strategy: strategy, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        $storage().defaultStrategyByAsset[asset] = strategy;
        emit DefaultStrategySet(asset, strategy);
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
            ErrorsLib.AddressNotWhitelisted()
        );
        uint256 amountToWithdraw;
        if (deallocation.amount == 0) {
            amountToWithdraw = _getAssetBalanceInStrategy(IERC4626(deallocation.strategy));
        } else {
            amountToWithdraw = deallocation.amount;
        }
        _withdrawFromStrategy(deallocation.asset, amountToWithdraw, address(this), deallocation.strategy);
    }

    function _swap(SwapParams memory swap) internal {
        require(
            IAssetRegistry(ASSET_REGISTRY).isSwapInputAllowed(swap.assetIn), ErrorsLib.UnsupportedAsset(swap.assetIn)
        );
        require(
            IAssetRegistry(ASSET_REGISTRY).isSwapOutputAllowed(swap.assetOut), ErrorsLib.UnsupportedAsset(swap.assetOut)
        );
        _validateSwapAmountIn(swap.assetIn, swap.amountIn, swap.assetOut);

        // Transfer assetIn to the swapper
        IERC20(swap.assetIn).safeTransfer(swap.swapper, swap.amountIn);

        // Execute the swap and require 1:1 conversion
        uint256 amountOut = ISwapper(swap.swapper).executeSwap(swap.assetIn, swap.assetOut, swap.amountIn, swap.data);
        require(
            amountOut >= swap.amountIn.convertAssetDecimals(swap.assetIn, swap.assetOut),
            ErrorsLib.InsufficientAmountOut()
        );

        // Pull the `assetOut` from the Swapper to the Allocator
        IERC20(swap.assetOut).safeTransferFrom(swap.swapper, address(this), amountOut);
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
            require(amountIn % 10 ** (inputDecimals - outputDecimals) == 0, ErrorsLib.InvalidAmount());
        }
    }

    function _allocate(AllocationParams memory allocation) internal {
        require(
            _isStrategySupportedForAsset({strategy: allocation.strategy, asset: allocation.asset}),
            ErrorsLib.AddressNotWhitelisted()
        );
        uint256 amountToAllocate;
        if (allocation.amount == 0) {
            amountToAllocate = IERC20(allocation.asset).balanceOf(address(this));
        } else {
            amountToAllocate = allocation.amount;
        }
        bool callSucceeded =
            _depositToStrategy({asset: allocation.asset, amount: amountToAllocate, strategy: allocation.strategy});
        require(callSucceeded, IAllocator.DepositIntoStrategyFailed(allocation.strategy));
    }

    function _tryWithdrawFromStrategy(address asset, uint256 amount, address strategy) internal returns (uint256) {
        uint256 withdrawnAmount;
        uint256 balanceInStrategy = _getAssetBalanceInStrategy(IERC4626(strategy));
        if (balanceInStrategy > 0) {
            withdrawnAmount = balanceInStrategy > amount ? amount : balanceInStrategy;
            _withdrawFromStrategy(asset, withdrawnAmount, address(this), strategy);
        }
        return withdrawnAmount;
    }

    /// @dev Intended to be the lowest level function used to withdraw from a strategy.
    function _withdrawFromStrategy(address asset, uint256 amount, address receiver, address strategy) internal {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC4626(strategy).withdraw({assets: amount, receiver: receiver, owner: address(this)});
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        require(balanceAfter - balanceBefore == amount, ErrorsLib.InsufficientAmountOut());
        emit AssetDeallocated(asset, strategy, amount);
    }

    /// @dev Intended to be the lowest level function used to deposit into a strategy.
    function _depositToStrategy(address asset, uint256 amount, address strategy) internal returns (bool) {
        require(amount > 0, ErrorsLib.ZeroAmount());
        require(IAssetRegistry(ASSET_REGISTRY).isDepositToAllocatorAllowed(asset), ErrorsLib.UnsupportedAsset(asset));
        if (strategy == address(0)) {
            // A strategy for this asset is not set, so the funds stay idle in the Allocator.
            return true;
        }
        IERC20(asset).forceApprove(strategy, amount);
        (bool callSucceeded,) = strategy.call(abi.encodeCall(IERC4626.deposit, (amount, address(this))));

        if (!callSucceeded) {
            // Clear the approval since this failure is handled gracefully
            IERC20(asset).forceApprove(strategy, 0);
            emit StrategyDepositFailed(strategy, amount);
        } else {
            emit AssetAllocated(asset, strategy, amount);
        }
        return callSucceeded;
    }

    /// @dev Returns balances grouped by asset.
    function _getAssetBalances() internal view returns (IAllocator.AllocatorBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatedAssets =
            new IAllocator.AllocatorBalance[]($storage().assetsWithSupportedStrategies.length);
        for (uint256 i = 0; i < $storage().assetsWithSupportedStrategies.length; i++) {
            address asset = $storage().assetsWithSupportedStrategies[i];
            allocatedAssets[i] = IAllocator.AllocatorBalance({asset: asset, amount: _getTotalAssetBalance(asset)});
        }
        return allocatedAssets;
    }

    function _getTotalAssetBalance(address asset) internal view returns (uint256) {
        uint256 balance = 0;
        for (uint256 i = 0; i < $storage().assetStrategies[asset].length; i++) {
            balance += _getAssetBalanceInStrategy(IERC4626($storage().assetStrategies[asset][i]));
        }
        balance += IERC20(asset).balanceOf(address(this));
        return balance;
    }

    function _getAssetBalanceInStrategy(IERC4626 strategy) internal view returns (uint256) {
        uint256 amount = strategy.previewRedeem(strategy.balanceOf(address(this)));
        return amount;
    }

    function _isStrategySupportedForAsset(address strategy, address asset) internal view returns (bool) {
        return $storage().strategyData[strategy].asset == asset;
    }

    function _isStrategySupported(address strategy) internal view returns (bool) {
        return $storage().strategyData[strategy].asset != address(0);
    }

    function _addStrategy(address asset, address strategy) internal {
        require(!_isStrategySupported(strategy), ErrorsLib.AddressAlreadyWhitelisted());
        require(asset == IERC4626(strategy).asset(), ErrorsLib.InvalidAsset(asset));
        $storage().assetStrategies[asset].push(strategy);
        $storage().allStrategies.push(strategy);
        $storage().strategyData[strategy] = StrategyData({
            asset: asset,
            indexInAssetStrategies: uint32($storage().assetStrategies[asset].length - 1),
            indexInAllStrategies: uint32($storage().allStrategies.length - 1)
        });

        // Add asset to $storage().assetsWithSupportedStrategies if it is not already in the list
        if ($storage().assetStrategyCount[asset] == 0) {
            $storage().assetsWithSupportedStrategies.push(asset);
        }
        $storage().assetStrategyCount[asset]++;

        emit StrategyAdded(asset, strategy);
    }

    function _removeStrategy(address strategy) internal {
        StrategyData memory strategyData = $storage().strategyData[strategy];
        require(_isStrategySupported(strategy), ErrorsLib.AddressNotWhitelisted());
        if (strategy == $storage().defaultStrategyByAsset[strategyData.asset]) {
            // Unset the default strategy for the asset - deposits will not flow to this strategy.
            // If the default strategy is removed, another one should be set as the default for withdrawals.
            delete $storage().defaultStrategyByAsset[strategyData.asset];
            emit DefaultStrategySet(strategyData.asset, address(0));
        }

        // Remove strategy from $storage().assetStrategies
        if ($storage().assetStrategies[strategyData.asset].length > 1) {
            uint32 index = strategyData.indexInAssetStrategies;
            $storage().assetStrategies[strategyData.asset][index] = $storage()
            .assetStrategies[strategyData.asset][$storage().assetStrategies[strategyData.asset].length - 1];
            $storage().strategyData[$storage().assetStrategies[strategyData.asset][index]].indexInAssetStrategies =
            index;
        }
        $storage().assetStrategies[strategyData.asset].pop();

        // Remove strategy from $storage().allStrategies
        if ($storage().allStrategies.length > 1) {
            uint32 indexInAllStrategies = strategyData.indexInAllStrategies;
            $storage().allStrategies[indexInAllStrategies] =
                $storage().allStrategies[$storage().allStrategies.length - 1];
            $storage().strategyData[$storage().allStrategies[indexInAllStrategies]].indexInAllStrategies =
            indexInAllStrategies;
        }
        $storage().allStrategies.pop();

        // Update storage that tracks assets with supported strategies
        $storage().assetStrategyCount[strategyData.asset]--;
        if ($storage().assetStrategyCount[strategyData.asset] == 0) {
            // Remove asset from $storage().assetsWithSupportedStrategies
            for (uint256 i = 0; i < $storage().assetsWithSupportedStrategies.length; i++) {
                if ($storage().assetsWithSupportedStrategies[i] == strategyData.asset) {
                    $storage().assetsWithSupportedStrategies[i] =
                        $storage().assetsWithSupportedStrategies[$storage().assetsWithSupportedStrategies.length - 1];
                    $storage().assetsWithSupportedStrategies.pop();
                    break;
                }
            }
        }

        delete $storage().strategyData[strategy];
        emit StrategyRemoved(strategyData.asset, strategy);
    }
}
