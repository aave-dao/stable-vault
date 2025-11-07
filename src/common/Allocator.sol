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

    struct VaultData {
        address asset;
        uint32 indexInAssetVaults;
        uint32 indexInAllVaults;
    }

    address internal immutable DEPOSITOR;
    address internal immutable WITHDRAWER;
    address internal immutable ASSET_REGISTRY;

    // Strategy Vaults
    // - defaultVaultByAsset: The default vault for an asset which funds are deposited into and withdrawn from.
    // - allowedVaultsByAsset: Entire set of allowed vaults for an asset which funds can be reallocated to/from
    mapping(address asset => address vault) internal _defaultVaultByAsset;
    mapping(address vault => VaultData vaultData) internal _vaultData;
    // To iterate through all vaults for an asset.
    mapping(address asset => address[]) internal _assetVaults;
    // To allow O(1) lookup to see if asset should be added/removed from _assetsWithSupportedVaults.
    mapping(address asset => uint256 vaultsCount) internal _assetVaultsCount;
    // To iterate through all vaults.
    address[] internal _allVaults;
    // To iterate through all assets with supported vaults and collect their balances.
    address[] internal _assetsWithSupportedVaults;

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

    function getAssetBalanceInStrategy(address strategyVault) external view returns (uint256) {
        return _getAssetBalanceInVault(IERC4626(strategyVault));
    }

    /// @inheritdoc IAllocator
    function getAssetBalances() external view override returns (IAllocator.AllocatorBalance[] memory) {
        return _getAssetBalances();
    }

    /// @inheritdoc IAllocator
    function getDefaultVault(address asset) external view override returns (address) {
        return _defaultVaultByAsset[asset];
    }

    /// @inheritdoc IAllocator
    function isVaultSupportedForAsset(address asset, address vault) external view override returns (bool) {
        return _isVaultSupportedForAsset({vault: vault, asset: asset});
    }

    /// @inheritdoc IAllocator
    function isVaultSupported(address vault) external view override returns (bool) {
        return _isVaultSupported(vault);
    }

    /// @inheritdoc IAllocator
    function deposit(address asset, uint256 amount) external override onlyDepositor {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        bool callSucceeded = _deposit({asset: asset, amount: amount});
        if (!callSucceeded) {
            emit VaultDepositFailed(_defaultVaultByAsset[asset], amount);
        }
    }

    /// @inheritdoc IAllocator
    function withdraw(address asset, uint256 amount) external override onlyWithdrawer {
        _withdrawFromVault(asset, amount, _defaultVaultByAsset[asset]);
    }

    /// @inheritdoc IAllocator
    function withdrawFromStrategy(address asset, uint256 amount, address strategyVault)
        external
        override
        onlyWithdrawer
    {
        _withdrawFromVault(asset, amount, strategyVault == address(0) ? _defaultVaultByAsset[asset] : strategyVault);
    }

    // Manager Functions

    /// @inheritdoc IAllocator
    function deallocate(address asset, uint256 assetsAmount, address vault)
        external
        override
        restricted
        returns (uint256)
    {
        require(IERC4626(vault).asset() == asset, ErrorsLib.InvalidAsset(asset));
        if (assetsAmount == 0) {
            // If zero is passed, we withdraw the max amount using shares.
            uint256 maxShares = IERC4626(vault).maxRedeem(address(this));
            uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
            uint256 assetsWithdrawn = _deallocateShares(vault, asset, maxShares, address(this));
            uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
            require(balanceAfter - balanceBefore == assetsWithdrawn, ErrorsLib.InsufficientAmountOut());
            return maxShares;
        } else {
            uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
            uint256 sharesBurned = _deallocate(vault, asset, assetsAmount, address(this));
            uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
            require(balanceAfter - balanceBefore == assetsAmount, ErrorsLib.InsufficientAmountOut());
            return sharesBurned;
        }
    }

    /// @inheritdoc IAllocator
    function depositIdleFunds(address asset) external override restricted {
        uint256 amount = IERC20(asset).balanceOf(address(this));
        bool callSucceeded = _deposit({asset: asset, amount: amount});
        require(callSucceeded, ErrorsLib.VaultDepositFailed());
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
                // Withdraw assets from vault to this contract
                IERC4626(_defaultVaultByAsset[assetIn]).withdraw(amountIn - idleBalance, address(this), address(this));
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

            // Deposit the assetOut into the vault
            IERC20(params.swaps[i].assetOut).forceApprove(address(_defaultVaultByAsset[assetOut]), assetOutAmount);
            IERC4626(_defaultVaultByAsset[assetOut]).deposit(assetOutAmount, address(this));
        }
    }

    // TODO: Consider consolidating `rebalance` and `reallocate` functions into a single function.

    /// @inheritdoc IAllocator
    function reallocate(address asset, uint256 amount, address fromVault, address toVault)
        external
        override
        restricted
    {
        require(_isVaultSupportedForAsset({vault: fromVault, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        require(_isVaultSupportedForAsset({vault: toVault, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        // Pull the asset from the fromVault to the Allocator
        _deallocate(fromVault, asset, amount, address(this));
        // Push the asset to the toVault
        _deposit(asset, amount);
    }

    /// @inheritdoc IAllocator
    function addVault(address asset, address vault) external override restricted {
        _addVault(asset, vault);
    }

    /// @inheritdoc IAllocator
    function removeVault(address vault) external override restricted {
        _removeVault(vault);
    }

    /// @inheritdoc IAllocator
    function setDefaultVault(address asset, address vault) external restricted {
        // TODO: set behind timelock?
        // Vault must be allowed to be set as the default vault for the asset
        require(_defaultVaultByAsset[asset] != vault, ErrorsLib.AddressAlreadyWhitelisted());
        require(_isVaultSupportedForAsset({vault: vault, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        _defaultVaultByAsset[asset] = vault;
        emit DefaultVaultSet(asset, vault);
    }

    // Internal Functions

    function _deallocate(address vault, address asset, uint256 amount, address receiver) internal returns (uint256) {
        uint256 burnedShares = IERC4626(vault).withdraw({assets: amount, receiver: receiver, owner: address(this)});
        emit AssetDeallocated(asset, vault, amount, burnedShares);
        return burnedShares;
    }

    function _deallocateShares(address vault, address asset, uint256 sharesAmount, address receiver)
        internal
        returns (uint256)
    {
        uint256 assetsWithdrawn =
            IERC4626(vault).redeem({shares: sharesAmount, receiver: receiver, owner: address(this)});
        emit AssetDeallocated(asset, vault, assetsWithdrawn, sharesAmount);
        return assetsWithdrawn;
    }

    function _deposit(address asset, uint256 amount) internal returns (bool) {
        require(amount > 0, ErrorsLib.ZeroAmount());
        require(
            IAssetRegistry(ASSET_REGISTRY).isAllowedToDepositIntoAllocator(asset), ErrorsLib.UnsupportedAsset(asset)
        );
        address vault = _defaultVaultByAsset[asset];
        if (vault == address(0)) {
            // A strategy for this asset is not set, so the funds stay idle in the Allocator.
            return true;
        }
        IERC20(asset).forceApprove(vault, amount);
        return _callVaultWithData(vault, abi.encodeCall(IERC4626.deposit, (amount, address(this))));
    }

    function _withdrawFromVault(address asset, uint256 amount, address strategyVault) internal {
        require(amount > 0, ErrorsLib.ZeroAmount());
        require(
            IAssetRegistry(ASSET_REGISTRY).isAllowedToWithdrawFromAllocator(asset), ErrorsLib.UnsupportedAsset(asset)
        );
        uint256 idleBalance = IERC20(asset).balanceOf(address(this));

        if (idleBalance >= amount) {
            // Withdraw from idle funds directly to the msg.sender
            IERC20(asset).safeTransfer(msg.sender, amount);
            return;
        }

        require(_isVaultSupportedForAsset({vault: strategyVault, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        require(
            idleBalance + _getAssetBalanceInVault(IERC4626(strategyVault)) >= amount, ErrorsLib.InsufficientLiquidity()
        );
        // Deallocate as necessary then transfer `amount` to the msg.sender
        _deallocate(strategyVault, asset, amount - idleBalance, address(this));
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    /// @dev Returns balances grouped by asset.
    function _getAssetBalances() internal view returns (IAllocator.AllocatorBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatedAssets =
            new IAllocator.AllocatorBalance[](_assetsWithSupportedVaults.length);
        for (uint256 i = 0; i < _assetsWithSupportedVaults.length; i++) {
            address asset = _assetsWithSupportedVaults[i];
            allocatedAssets[i] = IAllocator.AllocatorBalance({asset: asset, amount: _getTotalAssetBalance(asset)});
        }
        return allocatedAssets;
    }

    function _getTotalAssetBalance(address asset) internal view returns (uint256) {
        uint256 balance = 0;
        for (uint256 i = 0; i < _assetVaults[asset].length; i++) {
            balance += _getAssetBalanceInVault(IERC4626(_assetVaults[asset][i]));
        }
        balance += IERC20(asset).balanceOf(address(this));
        return balance;
    }

    function _getAssetBalanceInVault(IERC4626 vault) internal view returns (uint256) {
        uint256 amount = vault.previewRedeem(vault.balanceOf(address(this)));
        return amount;
    }

    function _isVaultSupportedForAsset(address vault, address asset) internal view returns (bool) {
        return _vaultData[vault].asset == asset;
    }

    function _isVaultSupported(address vault) internal view returns (bool) {
        return _vaultData[vault].asset != address(0);
    }

    function _callVaultWithData(address vault, bytes memory data) internal returns (bool) {
        (bool callSucceeded,) = vault.call(data);
        return callSucceeded;
    }

    function _addVault(address asset, address vault) internal {
        require(!_isVaultSupported(vault), ErrorsLib.AddressAlreadyWhitelisted());
        require(IERC4626(vault).asset() == asset, ErrorsLib.InvalidAsset(asset));
        _assetVaults[asset].push(vault);
        _allVaults.push(vault);
        _vaultData[vault] = VaultData({
            asset: asset,
            indexInAssetVaults: uint32(_assetVaults[asset].length - 1),
            indexInAllVaults: uint32(_allVaults.length - 1)
        });

        // Add asset to _assetsWithSupportedVaults if it is not already in the list
        if (_assetVaultsCount[asset] == 0) {
            _assetsWithSupportedVaults.push(asset);
        }
        _assetVaultsCount[asset]++;

        emit VaultAdded(asset, vault);
    }

    function _removeVault(address vault) internal {
        VaultData memory vaultData = _vaultData[vault];
        require(_isVaultSupported(vault), ErrorsLib.AddressNotWhitelisted());
        if (vault == _defaultVaultByAsset[vaultData.asset]) {
            // Unset the default vault for the asset - deposits will not flow to this vault.
            // If the default vault is removed, another one should be set as the default for withdrawals.
            delete _defaultVaultByAsset[vaultData.asset];
            emit DefaultVaultSet(vaultData.asset, address(0));
        }

        // Remove vault from _assetVaults
        if (_assetVaults[vaultData.asset].length > 1) {
            uint32 index = vaultData.indexInAssetVaults;
            _assetVaults[vaultData.asset][index] =
                _assetVaults[vaultData.asset][_assetVaults[vaultData.asset].length - 1];
            _vaultData[vault].indexInAssetVaults = index;
        }
        _assetVaults[vaultData.asset].pop();

        // Remove vault from _allVaults
        if (_allVaults.length > 1) {
            uint32 indexInAllVaults = vaultData.indexInAllVaults;
            _allVaults[indexInAllVaults] = _allVaults[_allVaults.length - 1];
            _vaultData[vault].indexInAllVaults = indexInAllVaults;
        }
        _allVaults.pop();

        // Update storage that tracks assets with supported vaults
        _assetVaultsCount[vaultData.asset]--;
        if (_assetVaultsCount[vaultData.asset] == 0) {
            // Remove asset from _assetsWithSupportedVaults
            for (uint256 i = 0; i < _assetsWithSupportedVaults.length; i++) {
                if (_assetsWithSupportedVaults[i] == vaultData.asset) {
                    _assetsWithSupportedVaults[i] = _assetsWithSupportedVaults[_assetsWithSupportedVaults.length - 1];
                    _assetsWithSupportedVaults.pop();
                    break;
                }
            }
        }

        delete _vaultData[vault];
        emit VaultRemoved(vaultData.asset, vault);
    }
}
