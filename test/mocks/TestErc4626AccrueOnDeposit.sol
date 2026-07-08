// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockErc20} from "test/mocks/MockErc20.sol";

contract TestErc4626AccrueOnDeposit is ERC4626 {
    uint256 public pendingYield;
    uint256 public depositSlippage;

    constructor(IERC20 asset) ERC4626(asset) ERC20("Accrue-On-Deposit", "AOD") {}

    function setPendingYield(uint256 amount) external {
        pendingYield = amount;
    }

    function setDepositSlippage(uint256 amount) external {
        depositSlippage = amount;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        // Realise queued yield before share valuation, so new shares mint against the post-accrue state.
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
