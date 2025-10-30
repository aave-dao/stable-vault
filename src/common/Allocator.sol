// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

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
contract Allocator is IAllocator {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    address internal _manager;
    address internal _admin;
    address internal _assetRegistry;
    // uint256 public timelock;

    struct VaultData {
        address asset;
        uint32 indexInAssetVaults;
        uint32 indexInAllVaults;
    }

    mapping(address depositor => bool whitelisted) internal _whitelistedDepositor;
    mapping(address withdrawer => bool whitelisted) internal _whitelistedWithdrawer;
    // Strategy Vaults
    // - defaultVaultByAsset: The default vault for an asset which funds are deposited into and withdrawn from.
    // - allowedVaultsByAsset: Entire set of allowed vaults for an asset which funds can be reallocated to/from
    mapping(address asset => address vault) internal _defaultVaultByAsset;
    mapping(address vault => VaultData vaultData) internal _vaultData;
    // To iterate through all vaults for an asset
    mapping(address asset => address[]) internal _assetVaults;
    // To iterate through all vaults
    address[] internal _allVaults;

    modifier onlyWhitelistedDepositor() {
        require(_whitelistedDepositor[msg.sender], ErrorsLib.AddressNotWhitelisted());
        _;
    }

    modifier onlyWhitelistedWithdrawer() {
        require(_whitelistedWithdrawer[msg.sender], ErrorsLib.AddressNotWhitelisted());
        _;
    }

    modifier onlyManager() {
        require(msg.sender == _manager, ErrorsLib.NotManager());
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, ErrorsLib.NotAdmin());
        _;
    }

    constructor(address manager, address admin, address assetRegistry) {
        _manager = manager;
        _admin = admin;
        _assetRegistry = assetRegistry;
    }

    /// @inheritdoc IAllocator
    function getManager() external view override returns (address) {
        return _manager;
    }

    /// @inheritdoc IAllocator
    function getAdmin() external view override returns (address) {
        return _admin;
    }

    /// @inheritdoc IAllocator
    function getAssetBalance(address asset) external view override returns (uint256) {
        return _getTotalAssetBalance(asset);
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
    function deposit(address asset, uint256 amount) external override onlyWhitelistedDepositor {
        // TODO: check if Allocator supports deposit for asset
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        bool callSucceeded = _deposit({asset: asset, amount: amount});
        if (!callSucceeded) {
            emit VaultDepositFailed(_defaultVaultByAsset[asset], amount);
        }
    }

    /// @inheritdoc IAllocator
    function withdraw(address asset, uint256 amount) external override onlyWhitelistedWithdrawer {
        require(amount > 0, ErrorsLib.ZeroAmount());
        require(
            IAssetRegistry(_assetRegistry).isAllowedToWithdrawFromAllocator(asset), ErrorsLib.UnsupportedAsset(asset)
        );
        address vault = _defaultVaultByAsset[asset];
        uint256 idleBalance = IERC20(asset).balanceOf(address(this));

        if (idleBalance > 0 && amount > idleBalance) {
            // Deallocate as necessary then transfer `amount` to the msg.sender
            _deallocate(vault, asset, amount - idleBalance, address(this));
            IERC20(asset).safeTransfer(msg.sender, amount);
        } else {
            // Withdraw from strategy vault directly to the msg.sender
            _deallocate(vault, asset, amount, msg.sender);
        }
    }

    // Manager Functions

    /// @inheritdoc IAllocator
    function deallocate(address asset, uint256 assetsAmount, address vault)
        external
        override
        onlyManager
        returns (uint256)
    {
        require(_isVaultSupportedForAsset({vault: vault, asset: asset}), ErrorsLib.AddressAlreadyWhitelisted());
        require(IERC4626(vault).asset() == asset, ErrorsLib.InvalidAsset(asset));
        if (assetsAmount == 0) {
            // TODO: Add to documentation
            // Withdraw MAX special case
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
    function depositIdleFunds(address asset) external override onlyManager {
        uint256 amount = IERC20(asset).balanceOf(address(this));
        bool callSucceeded = _deposit({asset: asset, amount: amount});
        require(callSucceeded, ErrorsLib.VaultDepositFailed());
    }

    /// @inheritdoc IAllocator
    function rebalance(CrossAssetRebalanceParams memory params) external override onlyManager {
        for (uint256 i = 0; i < params.swaps.length; i++) {
            address assetIn = params.swaps[i].assetIn;
            require(
                IAssetRegistry(_assetRegistry).isAllowedSwapInputToken(assetIn), ErrorsLib.UnsupportedAsset(assetIn)
            );
            address assetOut = params.swaps[i].assetOut;
            require(
                IAssetRegistry(_assetRegistry).isAllowedSwapOutputToken(assetOut)
                    && IAssetRegistry(_assetRegistry).isAllowedToDepositIntoAllocator(assetOut),
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
        onlyManager
    {
        require(_isVaultSupportedForAsset({vault: fromVault, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        require(_isVaultSupportedForAsset({vault: toVault, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        // Pull the asset from the fromVault to the Allocator
        _deallocate(fromVault, asset, amount, address(this));
        // Push the asset to the toVault
        _deposit(asset, amount);
    }

    /// @inheritdoc IAllocator
    function addVault(address asset, address vault) external override onlyAdmin {
        _addVault(asset, vault);
    }

    /// @inheritdoc IAllocator
    function removeVault(address vault) external override onlyAdmin {
        _removeVault(vault);
    }

    /// @inheritdoc IAllocator
    function setDefaultVault(address asset, address vault) external onlyManager {
        // TODO: set behind timelock?
        // Vault must be allowed to be set as the default vault for the asset
        require(_defaultVaultByAsset[asset] != vault, ErrorsLib.AddressAlreadyWhitelisted());
        require(_isVaultSupportedForAsset({vault: vault, asset: asset}), ErrorsLib.AddressNotWhitelisted());
        _defaultVaultByAsset[asset] = vault;
        emit DefaultVaultSet(asset, vault);
    }

    // Admin Functions

    /// @inheritdoc IAllocator
    function setManager(address newManager) external override onlyAdmin {
        // TODO: set behind timelock
        require(newManager != address(0), ErrorsLib.ZeroAddress());
        _manager = newManager;
    }

    /// @inheritdoc IAllocator
    function setDepositor(address depositor, bool whitelisted) external override onlyAdmin {
        // TODO: set behind timelock?
        require(depositor != address(0), ErrorsLib.ZeroAddress());
        require(_whitelistedDepositor[depositor] != whitelisted, ErrorsLib.AddressAlreadyWhitelisted());
        _whitelistedDepositor[depositor] = whitelisted;
    }

    /// @inheritdoc IAllocator
    function setWithdrawer(address withdrawer, bool whitelisted) external override onlyAdmin {
        // TODO: set behind timelock?
        require(withdrawer != address(0), ErrorsLib.ZeroAddress());
        require(_whitelistedWithdrawer[withdrawer] != whitelisted, ErrorsLib.AddressAlreadyWhitelisted());
        _whitelistedWithdrawer[withdrawer] = whitelisted;
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
        require(
            IAssetRegistry(_assetRegistry).isAllowedToDepositIntoAllocator(asset), ErrorsLib.UnsupportedAsset(asset)
        );
        address vault = _defaultVaultByAsset[asset];
        if (vault == address(0)) {
            // There is not strategy for this asset
            return true;
        }
        require(amount > 0, ErrorsLib.ZeroAmount());
        IERC20(asset).forceApprove(vault, amount);
        return _callVaultWithData(vault, abi.encodeCall(IERC4626.deposit, (amount, address(this))));
    }

    function _getAssetBalances() internal view returns (IAllocator.AllocatorBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatedAssets = new IAllocator.AllocatorBalance[](_allVaults.length);
        for (uint256 i = 0; i < _allVaults.length; i++) {
            address asset = IERC4626(_allVaults[i]).asset();
            allocatedAssets[i] = IAllocator.AllocatorBalance(asset, _getTotalAssetBalance(asset));
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
        emit VaultAdded(asset, vault);
    }

    function _removeVault(address vault) internal {
        VaultData memory vaultData = _vaultData[vault];
        require(_isVaultSupported(vault), ErrorsLib.AddressNotWhitelisted());
        if (vault == _defaultVaultByAsset[vaultData.asset]) {
            // Unset the default vault for the asset - deposits will not flow to this vault.
            // If the default vault is removed, another one should be set as the default for withdrawals.
            _unsetDefaultVault(vaultData.asset);
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

        delete _vaultData[vault];
        emit VaultRemoved(vaultData.asset, vault);
    }

    function _unsetDefaultVault(address asset) internal {
        require(_defaultVaultByAsset[asset] != address(0), ErrorsLib.AddressNotWhitelisted());
        _defaultVaultByAsset[asset] = address(0);
        emit DefaultVaultSet(asset, address(0));
    }
}
