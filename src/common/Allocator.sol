// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAllocator} from "../interfaces/IAllocator.sol";
import {IManagedAllocator} from "../interfaces/IManagedAllocator.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @dev Assumptions:
///      - 1 strategy per asset
///      - multiple assets per allocator with a common denomination
///      - assets are in their native decimals
///      - 100% of assets deposited into Allocator belong to the same entity
/// @dev Deals with assets in their native decimals.
contract Allocator is IManagedAllocator {
    // TODO: consider scenarios where tokens are left idle here because pushing to strategies fails (reverts should be
    // caught)
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    address internal _manager;
    address internal _admin;

    // uint256 public timelock;

    // TODO: do we need a supported assets mapping/list? Can the allocator receive assets that it must swap from?
    mapping(address depositor => bool whitelisted) internal _whitelistedDepositor;
    mapping(address withdrawer => bool whitelisted) internal _whitelistedWithdrawer;
    mapping(address asset => address vault) internal _vaultByAsset;
    address[] internal _vaults; // TODO: Think how we handle/populate this (when whitelisting probably? constructor?)

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

    constructor(address manager, address admin) {
        _manager = manager;
        _admin = admin;
    }

    /// @inheritdoc IAllocator
    function getManager() external view returns (address) {
        return _manager;
    }

    /// @inheritdoc IAllocator
    function getAdmin() external view returns (address) {
        return _admin;
    }

    /// @inheritdoc IAllocator
    function getAssetBalance(address asset) external view override returns (uint256) {
        return _getAssetBalance(asset);
    }

    /// @inheritdoc IAllocator
    function getAssetBalances() external view override returns (IManagedAllocator.AllocatorBalance[] memory) {
        return _getAssetBalances();
    }

    /// @inheritdoc IAllocator
    function deposit(address asset, uint256 amount) external override onlyWhitelistedDepositor {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        bool callSucceeded = _deposit({asset: asset, amount: amount});
        if (!callSucceeded) {
            emit VaultDepositFailed(_vaultByAsset[asset], amount);
        }
    }

    /// @inheritdoc IAllocator
    function withdraw(address asset, uint256 amount) external override onlyWhitelistedWithdrawer {
        address vault = _vaultByAsset[asset];
        require(vault != address(0), ErrorsLib.UnsupportedAsset(asset));
        require(amount > 0, ErrorsLib.ZeroAmount());
        uint256 idleBalance = IERC20(asset).balanceOf(address(this));

        uint256 burnedShares;
        uint256 amountToDeallocate = amount;
        if (idleBalance > 0 && amount > idleBalance) {
            amountToDeallocate = amount - idleBalance;
            burnedShares =
                IERC4626(vault).withdraw({assets: amountToDeallocate, receiver: address(this), owner: address(this)});
            IERC20(asset).safeTransfer(msg.sender, amount);
        } else {
            burnedShares =
                IERC4626(vault).withdraw({assets: amountToDeallocate, receiver: msg.sender, owner: address(this)});
        }
        emit Deallocation(asset, vault, amountToDeallocate, burnedShares);
    }

    /// @inheritdoc IAllocator
    function withdrawEmergency(
        uint256 /* amount */
    )
        external
        view
        override
        onlyWhitelistedWithdrawer
        returns (address)
    {
        // TODO: Implement pull asset from vault based on priority? Based on default? Iterate through and try which ever
        // has funds?
        // TODO: try to avoid dealing with assets in RAY as this contract deals with assets in their native decimals.
        revert("Allocator.withdrawEmergency:NOT_IMPLEMENTED");
    }

    /// @inheritdoc IManagedAllocator
    function deallocate(address asset, uint256 amount) external onlyManager {
        address vault = _vaultByAsset[asset];
        require(vault != address(0), ErrorsLib.UnsupportedAsset(asset));
        require(amount > 0, ErrorsLib.ZeroAmount());
        uint256 burnedShares = IERC4626(vault).withdraw({assets: amount, receiver: address(this), owner: address(this)});
        emit Deallocation(asset, vault, amount, burnedShares);
    }

    /// @inheritdoc IManagedAllocator
    function depositIdleFunds(address asset) external onlyManager {
        uint256 amount = IERC20(asset).balanceOf(address(this));
        bool callSucceeded = _deposit({asset: asset, amount: amount});
        require(callSucceeded, ErrorsLib.VaultDepositFailed());
    }

    /// @inheritdoc IManagedAllocator
    function rebalance(CrossAssetRebalanceParams memory params) external override onlyManager {
        for (uint256 i = 0; i < params.swaps.length; i++) {
            address assetIn = params.swaps[i].assetIn;
            require(_vaultByAsset[assetIn] != address(0), ErrorsLib.UnsupportedAsset(assetIn));
            address assetOut = params.swaps[i].assetOut;
            require(_vaultByAsset[assetOut] != address(0), ErrorsLib.UnsupportedAsset(assetOut));
            uint256 amountIn = params.swaps[i].amountIn;
            // Withdraw assets from vault to this contract
            IERC4626(_vaultByAsset[assetIn]).withdraw(amountIn, address(this), address(this));
            address swapper = params.swaps[i].swapper;
            // Transfer assetIn to the swapper
            IERC20(params.swaps[i].assetIn).safeTransfer(swapper, amountIn);
            // Execute the swap; rely on the swapper to enforce slippage constraints and send the toAsset back to the
            // Allocator
            uint256 assetOutAmount = ISwapper(swapper)
                .executeSwap(params.swaps[i].assetIn, params.swaps[i].assetOut, amountIn, params.swaps[i].swapData);

            require(
                assetOutAmount >= amountIn.convertAssetDecimals(assetIn, assetOut), ErrorsLib.InsufficientAmountOut()
            );

            // Pull the `assetOut` from the Swapper to the Allocator
            IERC20(params.swaps[i].assetOut).safeTransferFrom(swapper, address(this), assetOutAmount);

            // Deposit the assetOut into the vault
            IERC20(params.swaps[i].assetOut).forceApprove(address(_vaultByAsset[assetOut]), assetOutAmount);
            IERC4626(_vaultByAsset[assetOut]).deposit(assetOutAmount, address(this));
        }
    }

    function setManager(address newManager) external onlyAdmin {
        // TODO: set behind timelock
        require(newManager != address(0), ErrorsLib.ZeroAddress());
        _manager = newManager;
    }

    function setDepositor(address depositor, bool whitelisted) external onlyAdmin {
        // TODO: set behind timelock?
        require(depositor != address(0), ErrorsLib.ZeroAddress());
        require(_whitelistedDepositor[depositor] != whitelisted, ErrorsLib.AddressAlreadyWhitelisted());
        _whitelistedDepositor[depositor] = whitelisted;
    }

    function setWithdrawer(address withdrawer, bool whitelisted) external onlyAdmin {
        // TODO: set behind timelock?
        require(withdrawer != address(0), ErrorsLib.ZeroAddress());
        require(_whitelistedWithdrawer[withdrawer] != whitelisted, ErrorsLib.AddressAlreadyWhitelisted());
        _whitelistedWithdrawer[withdrawer] = whitelisted;
    }

    function setVault(address asset, address vault) external onlyManager {
        // TODO: set behind timelock?
        require(asset != address(0), ErrorsLib.ZeroAddress());
        require(vault != address(0), ErrorsLib.ZeroAddress());
        require(_vaultByAsset[asset] != vault, ErrorsLib.AddressAlreadyWhitelisted());
        address currentVault = _vaultByAsset[asset];
        if (currentVault != address(0)) {
            for (uint16 i = 0; i < _vaults.length; i++) {
                if (_vaults[i] == currentVault) {
                    _vaults[i] = vault;
                    break;
                }
            }
        } else {
            _vaults.push(vault);
        }
        _vaultByAsset[asset] = vault;
    }

    function _deposit(address asset, uint256 amount) internal returns (bool) {
        address vault = _vaultByAsset[asset];
        require(vault != address(0), ErrorsLib.UnsupportedAsset(asset));
        require(amount > 0, ErrorsLib.ZeroAmount());
        IERC20(asset).forceApprove(vault, amount);
        (bool callSucceeded,) = vault.call(abi.encodeCall(IERC4626.deposit, (amount, address(this))));
        return callSucceeded;
    }

    // TODO: Add to the interface
    function getVault(address asset) external view returns (address) {
        return _vaultByAsset[asset];
    }

    function _getAssetBalances() internal view returns (IManagedAllocator.AllocatorBalance[] memory) {
        IManagedAllocator.AllocatorBalance[] memory allocatedAssets =
            new IManagedAllocator.AllocatorBalance[](_vaults.length);
        for (uint256 i = 0; i < _vaults.length; i++) {
            IERC4626 vault = IERC4626(_vaults[i]);
            address asset = vault.asset();
            allocatedAssets[i] = IAllocator.AllocatorBalance(asset, _getTotalAssetBalance(asset, vault));
        }
        return allocatedAssets;
    }

    // Assumes single vault per asset
    function _getAssetBalance(address asset) internal view returns (uint256) {
        return _getTotalAssetBalance(asset, IERC4626(_vaultByAsset[asset]));
    }

    function _getTotalAssetBalance(address asset, IERC4626 vault) internal view returns (uint256) {
        uint256 amount = vault.previewRedeem(vault.balanceOf(address(this)));
        // Include idle funds in balance (assumes 1 vault per asset)
        amount += IERC20(asset).balanceOf(address(this));
        return amount;
    }
}
