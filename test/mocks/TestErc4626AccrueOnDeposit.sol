// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockErc20} from "test/mocks/MockErc20.sol";

/// @notice ERC4626 mock that simulates a yield-bearing strategy whose `deposit` first realizes pending external
/// yield (mints `pendingYield` of the underlying into itself) and then mints shares against the post-accrue state.
/// Mirrors the shape of `ATokenVault._handleDeposit` (`_accrueYield()` BEFORE `_baseDeposit`).
/// @dev Optional `depositSlippage` lets the test deduct a slippage from the deposited assets used for share-minting,
/// so we can verify the Allocator's `STRATEGY_DEPOSIT_SLIPPAGE_TOLERANCE` check is correctly gated against the
/// realised loss and is NOT masked by the in-deposit accrual.
contract TestErc4626AccrueOnDeposit is ERC4626 {
    uint256 public pendingYield;
    uint256 public depositSlippage;

    constructor(IERC20 asset) ERC4626(asset) ERC20("Accrue-On-Deposit", "AOD") {}

    /// @notice Queue `amount` of underlying yield to be minted into the vault on the next deposit.
    function setPendingYield(uint256 amount) external {
        pendingYield = amount;
    }

    /// @notice Per-deposit slippage in asset units, deducted from the assets used to mint shares so the receiver
    /// gets fewer shares than the assets they put in.
    function setDepositSlippage(uint256 amount) external {
        depositSlippage = amount;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        // Mint the queued pending yield into the vault BEFORE the deposit accounts for it. Mirrors the
        // ATokenVault._accrueYield() step, where the strategy's totalAssets grows before new shares are valued.
        if (pendingYield > 0) {
            MockErc20(asset()).mint(address(this), pendingYield);
            pendingYield = 0;
        }

        uint256 effectiveAssets = assets > depositSlippage ? assets - depositSlippage : 0;
        uint256 shares = _convertToShares(effectiveAssets, Math.Rounding.Floor);
        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }
}
