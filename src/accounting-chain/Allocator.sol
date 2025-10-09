// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {IAllocator} from "./interfaces/IAllocator.sol";

import {ISwapper} from "./interfaces/ISwapper.sol";

/// @dev Assumptions:
///      - 1 strategy per asset
///      - multiple assets per allocator with a common denomination
///      - assets are in their native decimals
///      - 100% of assets deposited into Allocator belong to the same entity
/// @dev Deals with assets in their native decimals
contract Allocator is IAllocator {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    address public manager;
    address public admin;

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
        require(msg.sender == manager, ErrorsLib.NotManager());
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, ErrorsLib.NotAdmin());
        _;
    }

    constructor(address _manager, address _admin) {
        manager = _manager;
        admin = _admin;
    }

    function getAssets() external view returns (IAllocator.AllocatedAssets[] memory) {
        IAllocator.AllocatedAssets[] memory allocatedAssets = new IAllocator.AllocatedAssets[](_vaults.length);
        for (uint256 i = 0; i < _vaults.length; i++) {
            address asset = IERC4626(_vaults[i]).asset();
            uint256 amount = IERC4626(_vaults[i]).maxWithdraw(address(this));
            // TODO: Sum by asset if multiple vaults per asset?
            allocatedAssets[i] = IAllocator.AllocatedAssets(asset, amount);
        }
        return allocatedAssets;
    }

    /// @return amount of total assets in all the vaults in RAY
    function getTotalAssets() external view returns (uint256) {
        uint256 totalAssetsInRay;
        for (uint256 i = 0; i < _vaults.length; i++) {
            uint256 assetAmount = IERC4626(_vaults[i]).maxWithdraw(address(this));
            address asset = IERC4626(_vaults[i]).asset();
            uint256 amountInRay = assetAmount.assetDecimalsToRay(asset);
            totalAssetsInRay += amountInRay;
        }
        return totalAssetsInRay;
    }

    function deposit(address asset, uint256 amount) external onlyWhitelistedDepositor {
        address vault = _vaultByAsset[asset];
        require(vault != address(0), ErrorsLib.UnsupportedAsset(asset));
        require(amount > 0, ErrorsLib.ZeroAmount());
        // Pull assets from the depositor
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // Deposit assets into strategy vault
        IERC20(asset).forceApprove(vault, amount); // TODO: Review if forceApprove or safeIncreaseAllowance
        /*  uint256 shares = */
        IERC4626(vault).deposit(amount, address(this));
        // TODO: Think what we do with the shares amount - do we save it? return it?
        // return shares;
    }

    function withdraw(address asset, uint256 amount) external onlyWhitelistedWithdrawer {
        address vault = _vaultByAsset[asset];
        require(vault != address(0), ErrorsLib.UnsupportedAsset(asset));
        require(amount > 0, ErrorsLib.ZeroAmount());
        // Withdraw assets from strategy vault
        IERC4626(vault).withdraw(amount, msg.sender, address(this));
    }

    /// Request any asset from the allocator for a given amount; assumes allocator assets have common denomination.
    function withdrawEmergency(uint256 amount) external view onlyWhitelistedWithdrawer returns (address asset) {
        (amount);
        // TODO: Implement pull asset from vault based on priority? Based on default? Iterate through and try which ever has funds?
        return address(0);
    }

    /// @inheritdoc IAllocator
    function rebalance(CrossAssetRebalanceParams memory params) external onlyManager {
        require(_vaultByAsset[params.coverageToken] != address(0), ErrorsLib.UnsupportedAsset(params.coverageToken));
        uint256 totalSlippageAmountRay;

        for (uint256 i = 0; i < params.swaps.length; i++) {
            address fromAsset = params.swaps[i].fromAsset;
            require(_vaultByAsset[fromAsset] != address(0), ErrorsLib.UnsupportedAsset(fromAsset));
            address toAsset = params.swaps[i].toAsset;
            require(_vaultByAsset[toAsset] != address(0), ErrorsLib.UnsupportedAsset(toAsset));
            uint256 amount = params.swaps[i].fromAmount;
            // Withdraw assets from vault to this contract
            IERC4626(_vaultByAsset[fromAsset]).withdraw(amount, address(this), address(this));
            address swapper = params.swaps[i].swapContract;
            // Transfer fromAssets to the swapper
            IERC20(params.swaps[i].fromAsset).safeTransfer(swapper, amount);
            // Execute the swap; rely on the swapper to enforce slippage constraints and send the toAsset back to the Allocator
            uint256 toAssetAmount = ISwapper(swapper).executeSwap(
                params.swaps[i].fromAsset,
                amount,
                params.swaps[i].toAsset,
                params.swaps[i].slippageToleranceBps,
                params.swaps[i].swapData
            );

            // Slippage check
            totalSlippageAmountRay += params.swaps[i].fromAmount.assetDecimalsToRay(params.swaps[i].fromAsset)
                - toAssetAmount.assetDecimalsToRay(params.swaps[i].toAsset);

            // Pull the `toAsset` from the Swapper to the Allocator
            IERC20(params.swaps[i].toAsset).safeTransferFrom(swapper, address(this), toAssetAmount);

            // Deposit the toAsset into the vault
            IERC20(params.swaps[i].toAsset).forceApprove(address(_vaultByAsset[toAsset]), toAssetAmount);
            IERC4626(_vaultByAsset[toAsset]).deposit(toAssetAmount, address(this));
        }

        if (totalSlippageAmountRay > 0) {
            // Pull tokens from the coverage token owner to cover slippage and/or fees
            IERC20(params.coverageToken).safeTransferFrom(
                params.coverageTokenOwner,
                address(this),
                totalSlippageAmountRay.rayToAssetDecimals(params.coverageToken)
            );
            // Supply the coverage token to the vault
            IERC20(params.coverageToken).forceApprove(
                address(_vaultByAsset[params.coverageToken]),
                totalSlippageAmountRay.rayToAssetDecimals(params.coverageToken)
            );
            IERC4626(_vaultByAsset[params.coverageToken]).deposit(
                totalSlippageAmountRay.rayToAssetDecimals(params.coverageToken), address(this)
            );
        }
    }

    function setManager(address newManager) external onlyAdmin {
        // TODO: set behind timelock
        require(newManager != address(0), ErrorsLib.ZeroAddress());
        manager = newManager;
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
        require(_vaultByAsset[asset] == vault, ErrorsLib.AddressAlreadyWhitelisted());
        // TODO: check vault supports IERC4626 with EIP-165?
        _vaultByAsset[asset] = vault;
    }
}
