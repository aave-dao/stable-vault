// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TestErc4626WithSlippage is ERC4626 {
    uint256 public depositSlippage;
    uint256 public depositBonus;
    uint256 private _slippageLoss;
    uint256 private _bonusGain;

    constructor(IERC20 asset) ERC4626(asset) ERC20("Test Erc4626", "TEST4626") {}

    function setDepositSlippage(uint256 slippage) external {
        depositSlippage = slippage;
        depositBonus = 0;
    }

    function setDepositBonus(uint256 bonus) external {
        depositBonus = bonus;
        depositSlippage = 0;
    }

    /// @dev Override totalAssets to account for slippage losses and bonus gains
    function totalAssets() public view override returns (uint256) {
        uint256 actualBalance = IERC20(asset()).balanceOf(address(this));
        uint256 adjustedBalance = actualBalance + _bonusGain;
        return adjustedBalance > _slippageLoss ? adjustedBalance - _slippageLoss : 0;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets - 1, shares);

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        uint256 slippageAssets = assets > 0 ? assets - 1 : 0;
        _withdraw(_msgSender(), receiver, owner, slippageAssets, shares);

        return assets;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 effectiveAssets;
        uint256 currentBonus = depositBonus;
        uint256 currentSlippage = depositSlippage;

        if (currentBonus > 0) {
            // Negative slippage: strategy gives bonus value
            effectiveAssets = assets + currentBonus;
        } else if (currentSlippage > 0) {
            // Positive slippage: strategy takes fee
            effectiveAssets = assets > currentSlippage ? assets - currentSlippage : 0;
        } else {
            effectiveAssets = assets;
        }

        // Calculate shares BEFORE updating state
        uint256 shares = _convertToShares(effectiveAssets, Math.Rounding.Floor);
        _deposit(_msgSender(), receiver, assets, shares);

        // Update state AFTER deposit to avoid affecting share calculation
        if (currentBonus > 0) {
            _bonusGain += currentBonus;
        } else if (currentSlippage > 0) {
            _slippageLoss += currentSlippage;
        }

        return shares;
    }
}
