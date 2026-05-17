// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IRebalancePolicy} from "src/interfaces/IRebalancePolicy.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {RescuableToken} from "src/misc/RescuableToken.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Errors} from "src/types/Errors.sol";

/// @title Allocator
/// @author Aave Labs
/// @notice Allocator contract for managing asset allocations into yield strategies.
/// @dev This contract supports batching of calls using the Multicall contract.
/// @dev Assumptions:
///      - multiple allowed strategies per asset; deposits are always idle until the manager rebalances them
///      - assumes all assets in Allocator share a common denomination
///      - asset amounts are treated in their native decimals
///      - 100% of assets deposited into Allocator belong to the same entity (the Allocator does not track depositors)
/// @custom:upgradeable
contract Allocator is
    AccessManagedUpgradeable,
    TransferHelperClient,
    Multicall,
    ReentrancyGuardTransientUpgradeable,
    RescuableToken,
    IAllocator
{
    using SafeERC20 for IERC20;
    using AssetLib for uint256;
    using MathLib for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    address internal immutable DEPOSITOR;
    address internal immutable WITHDRAWER;
    address internal immutable ASSET_REGISTRY;
    address internal immutable PRICE_ORACLE;
    address internal immutable POLICY_REGISTRY;
    uint8 internal immutable MAX_STRATEGIES_PER_ASSET;

    /// @dev Maximum slippage, denominated in asset units, tolerated to account for rounding errors when depositing
    /// to ERC-4626 yield strategies.
    uint8 internal constant STRATEGY_DEPOSIT_SLIPPAGE_TOLERANCE = 10;

    // keccak256("aave.stable-vault.Allocator.policy.rebalance")
    bytes32 internal constant REBALANCE_POLICY_ID = 0xc8677baa58e60e0903b82d16b92a11a49685a8844fe0f67b4f06e7d3ecef34cb;

    /// @custom:storage-location erc7201:aave.storage.Allocator
    struct AllocatorStorage {
        mapping(address strategy => StrategyConfig strategyConfig) strategyConfigs;
        mapping(address asset => EnumerableSet.AddressSet strategies) assetStrategies;
        mapping(address asset => address[] withdrawalQueue) withdrawalQueues;
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
    /// @param policyRegistry The address of the PolicyRegistry contract used to look up policies by ID.
    constructor(
        address assetRegistry,
        address depositor,
        address withdrawer,
        address priceOracle,
        address transferHelper,
        uint8 maxStrategiesPerAsset,
        address policyRegistry
    ) TransferHelperClient(transferHelper) {
        require(assetRegistry != address(0), Errors.ZeroAddress());
        require(depositor != address(0), Errors.ZeroAddress());
        require(withdrawer != address(0), Errors.ZeroAddress());
        require(priceOracle != address(0), Errors.ZeroAddress());
        require(policyRegistry != address(0), Errors.ZeroAddress());
        require(maxStrategiesPerAsset > 0, Errors.InvalidParameter());
        _disableInitializers();
        ASSET_REGISTRY = assetRegistry;
        DEPOSITOR = depositor;
        WITHDRAWER = withdrawer;
        PRICE_ORACLE = priceOracle;
        POLICY_REGISTRY = policyRegistry;
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
    function getAssetBalance(address asset) external view override returns (uint256) {
        return _getTotalAssetBalance({asset: asset, onlyTrustedStrategies: false});
    }

    /// @inheritdoc IAllocator
    function getAssetBalanceInStrategy(address strategy) external view override returns (uint256) {
        return _tryGetAssetBalanceInStrategy(IERC4626(strategy));
    }

    /// @inheritdoc IAllocator
    function getTrustedAssetBalances() external view override returns (IAllocator.AllocatorBalance[] memory) {
        return _getTrustedAssetBalances();
    }

    /// @inheritdoc IAllocator
    function getTrustedAssetBalance(address asset) external view override returns (uint256) {
        if (!IAssetRegistry(ASSET_REGISTRY).isAssetTrusted(asset)) {
            return 0;
        }
        return _getTotalAssetBalance({asset: asset, onlyTrustedStrategies: true});
    }

    /// @inheritdoc IAllocator
    function getStrategyConfig(address strategy) external view override returns (StrategyConfig memory) {
        return $storage().strategyConfigs[strategy];
    }

    /// @inheritdoc IAllocator
    function getStrategiesForAsset(address asset) external view override returns (address[] memory) {
        return $storage().assetStrategies[asset].values();
    }

    /// @inheritdoc IAllocator
    function getWithdrawalQueue(address asset) external view override returns (address[] memory) {
        return $storage().withdrawalQueues[asset];
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
    function deposit(address asset, uint256 amount) external override onlyDepositor nonReentrant {
        require(amount > 0, Errors.ZeroAmount());
        require(IAssetRegistry(ASSET_REGISTRY).isDepositToAllocatorAllowed(asset), Errors.UnsupportedAsset(asset));
        ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
        emit AssetLeftIdle(asset, amount);
    }

    /// @inheritdoc IAllocator
    function withdraw(address asset, uint256 amount) external override onlyWithdrawer nonReentrant {
        require(amount > 0, Errors.ZeroAmount());
        _validateCanWithdraw(asset);

        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        if (idleBalance < amount) {
            // Consume from idle balance first, then from all asset's strategies following the withdrawal queue order.
            uint256 amountRemaining = amount - idleBalance;
            address[] storage withdrawalQueue = $storage().withdrawalQueues[asset];
            uint256 strategiesCount = withdrawalQueue.length;
            for (uint256 i = 0; amountRemaining > 0 && i < strategiesCount; i++) {
                address strategy = withdrawalQueue[i];
                try this.tryWithdrawFromStrategy(asset, amountRemaining, strategy) returns (uint256 withdrawn) {
                    amountRemaining = amountRemaining.satSub(withdrawn);
                } catch {
                    emit StrategyWithdrawalFailed(strategy, asset, amountRemaining);
                }
            }
            require(amountRemaining == 0, Errors.InsufficientFunds());
        }
        _transferToTransferHelper(asset, amount);
    }

    /// @dev Implements the external and onlySelf modifier because this function is intended to be wrapped in a
    /// try-catch.
    /// @dev Avoids impact to searching other strategies if withdrawal from a previously searched strategy
    /// fails.
    /// @dev The `amount` param is clamped to the `strategy`'s available liquidity via `maxWithdraw` (with a balance
    /// fallback when `maxWithdraw` returns 0).
    function tryWithdrawFromStrategy(address asset, uint256 amount, address strategy)
        external
        onlySelf
        returns (uint256)
    {
        uint256 amountToWithdraw;
        uint256 withdrawnAmount;
        // Use maxWithdraw to account for withdrawal limits or timelocks.
        uint256 maxWithdrawable = IERC4626(strategy).maxWithdraw(address(this));
        if (maxWithdrawable == 0) {
            // Some ERC-4626 implementations may return 0 for `maxWithdraw` to adhere to the spec rule of not reverting.
            // Fallback to querying the balance that may not account for withdrawal limits or timelocks.
            amountToWithdraw = Math.min(amount, _tryGetAssetBalanceInStrategy(IERC4626(strategy)));
        } else {
            amountToWithdraw = Math.min(amount, maxWithdrawable);
        }
        if (amountToWithdraw != 0) {
            // withdrawnAmount is either equal or greater than amountToWithdraw (depending on the 4626 shares rounding).
            withdrawnAmount = _withdrawFromStrategy(asset, amountToWithdraw, strategy);
        }
        return withdrawnAmount;
    }

    //////////////////////////////////////////// MANAGER FUNCTIONS /////////////////////////////////////////////////////

    /// @inheritdoc IAllocator
    function rebalance(RebalanceParams[] memory params, bytes calldata policyData)
        external
        virtual
        override
        restricted
        nonReentrant
    {
        for (uint256 i = 0; i < params.length; i++) {
            _rebalance(params[i]);
        }
        // The policy is applied after the rebalance so it can assert against post-state invariants efficiently without
        // needing to parse the entire array of rebalance operations.
        _applyRebalancePolicy(params, policyData);
    }

    /// @inheritdoc IAllocator
    function topUp(address asset, uint256 amount) external override restricted {
        require(amount > 0, Errors.ZeroAmount());
        require(IAssetRegistry(ASSET_REGISTRY).isDepositToAllocatorAllowed(asset), Errors.UnsupportedAsset(asset));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit AssetToppedUp(asset, amount);
        emit AssetLeftIdle(asset, amount);
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
    function setWithdrawalQueue(address asset, address[] calldata newWithdrawalQueue) external override restricted {
        require(IAssetRegistry(ASSET_REGISTRY).isAssetRegistered(asset), Errors.InvalidAsset(asset));
        // Snapshot registered strategies into memory: the permutation check below indexes them n times and
        // EnumerableSet.at performs an SLOAD per call.
        address[] memory registeredStrategies = $storage().assetStrategies[asset].values();
        uint256 strategiesCount = registeredStrategies.length;
        require(newWithdrawalQueue.length == strategiesCount, InvalidWithdrawalQueue());

        // Verify that the withdrawal queue is a strict permutation of the asset's registered strategies.
        for (uint256 i = 0; i < strategiesCount; i++) {
            address strategy = registeredStrategies[i];
            bool strategyFoundInQueue = false;
            for (uint256 j = 0; j < strategiesCount; j++) {
                if (newWithdrawalQueue[j] == strategy) {
                    strategyFoundInQueue = true;
                    break;
                }
            }
            require(strategyFoundInQueue, InvalidWithdrawalQueue());
        }

        // Overwrite the current withdrawal queue with the new one.
        address[] storage withdrawalQueue = $storage().withdrawalQueues[asset];
        for (uint256 i = 0; i < strategiesCount; i++) {
            withdrawalQueue[i] = newWithdrawalQueue[i];
        }

        emit WithdrawalQueueSet(asset, newWithdrawalQueue);
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
        require($storage().strategyConfigs[strategy].isTrusted, StrategyNotTrusted(strategy));
        $storage().strategyConfigs[strategy].depositAllowed = true;
        emit StrategyDepositsToggled(strategy, true);
    }

    /// @inheritdoc IAllocator
    function trustStrategy(address strategy) external override restricted {
        require(_isStrategySupported(strategy), Errors.AddressNotWhitelisted());
        require(!$storage().strategyConfigs[strategy].isTrusted, Errors.AlreadyTrusted());
        $storage().strategyConfigs[strategy].isTrusted = true;
        emit StrategyTrusted(strategy);
    }

    /// @inheritdoc IAllocator
    function distrustStrategy(address strategy) external override restricted {
        require(_isStrategySupported(strategy), Errors.AddressNotWhitelisted());
        StrategyConfig storage _strategyConfig = $storage().strategyConfigs[strategy];
        require(_strategyConfig.isTrusted, Errors.AlreadyDistrusted());
        _strategyConfig.isTrusted = false;
        emit StrategyDistrusted(strategy);
        if (_strategyConfig.depositAllowed) {
            _strategyConfig.depositAllowed = false;
            emit StrategyDepositsToggled(strategy, false);
        }
    }

    /// @inheritdoc IAllocator
    function isStrategyTrusted(address strategy) external view override returns (bool) {
        return $storage().strategyConfigs[strategy].isTrusted;
    }

    ////////////////////////////////////////////////// INTERNAL ////////////////////////////////////////////////////////

    function _applyRebalancePolicy(RebalanceParams[] memory params, bytes calldata policyData) internal {
        address policy = IPolicyRegistry(POLICY_REGISTRY).getPolicy(REBALANCE_POLICY_ID);
        if (policy == address(0)) {
            return;
        }
        IRebalancePolicy(policy)
            .applyRebalancePolicy(
                IRebalancePolicy.RebalanceIntent({caller: msg.sender, params: params, policyData: policyData})
            );
    }

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
            _redeemAllAvailableFromStrategy(deallocation.asset, deallocation.strategy);
        } else {
            _withdrawFromStrategy(deallocation.asset, deallocation.amount, deallocation.strategy);
        }
    }

    function _swap(SwapParams memory swap) internal {
        require(swap.assetIn != swap.assetOut, Errors.InvalidParameter());
        require(IAssetRegistry(ASSET_REGISTRY).isSwapInputAllowed(swap.assetIn), Errors.UnsupportedAsset(swap.assetIn));
        require(
            IAssetRegistry(ASSET_REGISTRY).isSwapOutputAllowed(swap.assetOut), Errors.UnsupportedAsset(swap.assetOut)
        );
        _validateSwapAmountIn(swap.assetIn, swap.amountIn, swap.assetOut);
        IPriceOracle(PRICE_ORACLE).validatePrice(swap.assetOut);

        // Transfer assetIn to the swapper
        IERC20(swap.assetIn).safeTransfer(swap.swapper, swap.amountIn);

        // Execute the swap and require 1:1 conversion
        uint256 amountOut =
            ISwapper(swap.swapper).executeSwap(swap.assetIn, swap.assetOut, swap.amountIn, msg.sender, swap.data);
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
    /// @dev Uses redeem(previewWithdraw(amount)) instead of withdraw(amount) to capture
    /// the rounding surplus from ERC4626's ceil division on shares. Any surplus remains
    /// as idle balance in the Allocator, rounding in favor of the protocol.
    function _withdrawFromStrategy(address asset, uint256 amount, address strategy) internal returns (uint256) {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 sharesBalance = IERC4626(strategy).balanceOf(address(this));
        uint256 sharesToWithdraw = IERC4626(strategy).previewWithdraw(amount);
        if (sharesToWithdraw > sharesBalance) {
            sharesToWithdraw = sharesBalance;
        }
        IERC4626(strategy).redeem({shares: sharesToWithdraw, receiver: address(this), owner: address(this)});
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        uint256 actualAmountWithdrawn = balanceAfter - balanceBefore;
        require(actualAmountWithdrawn >= amount, Errors.InsufficientAmountOut());
        emit AssetDeallocated(asset, strategy, actualAmountWithdrawn);
        return actualAmountWithdrawn;
    }

    /// @dev Intended to be the lowest level function used to redeem all shares from a strategy.
    /// @dev Not intended to be used for withdrawals from the Allocator unless higher-level function handles reverts.
    function _redeemAllAvailableFromStrategy(address asset, address strategy) internal returns (uint256) {
        uint256 shares = IERC4626(strategy).balanceOf(address(this));
        require(shares > 0, ZeroShareBalance(strategy));
        uint256 maxRedeemable = IERC4626(strategy).maxRedeem(address(this));
        uint256 amount;
        if (maxRedeemable == 0) {
            // Some ERC-4626 implementations may return 0 for `maxRedeem` to adhere to the spec rule of not reverting.
            // Attempt to redeem all shares because the actual quantity of redeemable shares is unknown.
            amount = IERC4626(strategy).redeem({shares: shares, receiver: address(this), owner: address(this)});
        } else {
            amount = IERC4626(strategy)
                .redeem({shares: Math.min(shares, maxRedeemable), receiver: address(this), owner: address(this)});
        }
        emit AssetDeallocated(asset, strategy, amount);
        return amount;
    }

    /// @dev Intended to be the lowest level function used to deposit into a strategy.
    /// @dev Does not check if the strategy is trusted because to enable deposits for a strategy it must be trusted.
    /// @dev The state of strategy distrusted, but deposits are still allowed, is not possible.
    function _depositToStrategy(address asset, uint256 amount, address strategy) internal returns (uint256) {
        require(amount > 0, Errors.ZeroAmount());
        require($storage().strategyConfigs[strategy].depositAllowed, DepositsToStrategyDisabled(strategy));
        IERC20(asset).forceApprove(strategy, amount);

        uint256 actualDepositedAmount;
        try IERC4626(strategy).deposit(amount, address(this)) returns (uint256 shares) {
            actualDepositedAmount = IERC4626(strategy).previewRedeem(shares);
            require(
                amount.satSub(actualDepositedAmount) <= STRATEGY_DEPOSIT_SLIPPAGE_TOLERANCE,
                Errors.InsufficientAmountOut()
            );
        } catch {
            revert DepositIntoStrategyFailed(strategy);
        }

        // ERC4626 deposit may pull less than `amount`; clear the residual so dust doesn't accumulate as a latent
        // pull surface for the strategy.
        IERC20(asset).forceApprove(strategy, 0);

        emit AssetAllocated(asset, strategy, amount, actualDepositedAmount);
        return actualDepositedAmount;
    }

    /// @dev Returns balances grouped by asset.
    function _getTrustedAssetBalances() internal view returns (IAllocator.AllocatorBalance[] memory) {
        address[] memory assets = IAssetRegistry(ASSET_REGISTRY).getTrustedAssets();
        IAllocator.AllocatorBalance[] memory allocatedAssets = new IAllocator.AllocatorBalance[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            allocatedAssets[i] = IAllocator.AllocatorBalance({
                asset: asset, amount: _getTotalAssetBalance({asset: asset, onlyTrustedStrategies: true})
            });
        }
        return allocatedAssets;
    }

    function _getTotalAssetBalance(address asset, bool onlyTrustedStrategies) internal view returns (uint256) {
        uint256 balance = 0;
        uint256 strategiesLength = $storage().assetStrategies[asset].length();
        for (uint256 i = 0; i < strategiesLength; i++) {
            address strategy = $storage().assetStrategies[asset].at(i);
            if (!onlyTrustedStrategies || $storage().strategyConfigs[strategy].isTrusted) {
                balance += _tryGetAssetBalanceInStrategy(IERC4626(strategy));
            }
        }
        balance += IERC20(asset).balanceOf(address(this));
        return balance;
    }

    function _tryGetAssetBalanceInStrategy(IERC4626 strategy) internal view returns (uint256) {
        uint256 balance;
        uint256 shares = strategy.balanceOf(address(this));
        if (shares > 0) {
            try strategy.previewRedeem(shares) returns (uint256 amount) {
                balance = amount;
            } catch {
                balance = 0;
            }
        }
        return balance;
    }

    function _isStrategySupportedForAsset(address strategy, address asset) internal view returns (bool) {
        return $storage().strategyConfigs[strategy].asset == asset;
    }

    function _isStrategySupported(address strategy) internal view returns (bool) {
        return $storage().strategyConfigs[strategy].asset != address(0);
    }

    function _addStrategy(address asset, address strategy) internal {
        require(!_isStrategySupported(strategy), Errors.AddressAlreadyWhitelisted());
        require(IAssetRegistry(ASSET_REGISTRY).isAssetRegistered(asset), Errors.InvalidAsset(asset));
        require(asset == IERC4626(strategy).asset(), Errors.InvalidAsset(asset));

        $storage().strategyConfigs[strategy] =
            StrategyConfig({asset: asset, isRegistered: true, depositAllowed: true, isTrusted: true});
        $storage().assetStrategies[asset].add(strategy);
        _addToWithdrawalQueue(asset, strategy);

        require(
            $storage().assetStrategies[asset].length() <= MAX_STRATEGIES_PER_ASSET, IAllocator.TooManyStrategies(asset)
        );

        emit StrategyAdded(asset, strategy);
    }

    function _removeStrategy(address strategy) internal {
        address asset = $storage().strategyConfigs[strategy].asset;
        require(asset != address(0), Errors.AddressNotWhitelisted());
        // The calls to the strategy are not reliable if the strategy is not trusted.
        require($storage().strategyConfigs[strategy].isTrusted, StrategyNotTrusted(strategy));
        // This can get blocked if assets are deposited into the strategy on behalf of the Allocator.
        // This function is intended to clear storage, so if it gets DoS'd then the consequences are consumed storage.
        // This function does not allow removing a strategy if balance > 0 to avoid accidentally disregarding asset
        // balances when fetched by consumers.
        // This function does not force max withdraw from a strategy to avoid unintended behavior e.g. incurring
        // slippage.
        require(IERC4626(strategy).balanceOf(address(this)) == 0, StrategyStillHasFunds(strategy));
        $storage().assetStrategies[asset].remove(strategy);
        _removeFromWithdrawalQueue(asset, strategy);
        delete $storage().strategyConfigs[strategy];
        emit StrategyRemoved(asset, strategy);
    }

    function _addToWithdrawalQueue(address asset, address strategy) internal {
        address[] storage withdrawalQueue = $storage().withdrawalQueues[asset];
        withdrawalQueue.push(strategy);
        emit WithdrawalQueueSet(asset, withdrawalQueue);
    }

    /// @dev Removes `strategy` from the asset's withdrawal queue, shifting subsequent entries down by one so the
    /// relative order of the remaining strategies is preserved. Reverts if the strategy is not in the queue, which
    /// would signal a desync between `withdrawalQueues` and `assetStrategies` and should never happen.
    function _removeFromWithdrawalQueue(address asset, address strategy) internal {
        address[] storage withdrawalQueue = $storage().withdrawalQueues[asset];
        uint256 strategiesCount = withdrawalQueue.length;
        for (uint256 i = 0; i < strategiesCount; i++) {
            if (withdrawalQueue[i] == strategy) {
                unchecked {
                    for (uint256 j = i; j + 1 < strategiesCount; j++) {
                        withdrawalQueue[j] = withdrawalQueue[j + 1];
                    }
                }
                withdrawalQueue.pop();
                emit WithdrawalQueueSet(asset, withdrawalQueue);
                return;
            }
        }
        revert InvalidWithdrawalQueue();
    }

    function _beforeRescueTokens(address token, uint256) internal virtual override {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
        // Disallow rescuing registered assets, preventing the caller to take system funds through rescue function.
        require(!IAssetRegistry(ASSET_REGISTRY).isAssetRegistered(token), Errors.InvalidParameter());
        // Disallow rescuing strategy shares, preventing the caller to take system funds through rescue function.
        require(!$storage().strategyConfigs[token].isRegistered, Errors.InvalidParameter());
    }
}
