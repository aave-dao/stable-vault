// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ISwapper} from "../interfaces/ISwapper.sol";
import {AssetLib} from "../libraries/AssetLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Swapper
/// @notice Executes swaps through approved routers and selectors with slippage & access control.
contract FloatBasedSwapper is ISwapper, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    mapping(address asset => uint256 balanceSnapshot) _balances;

    constructor(address owner) Ownable(owner) {}

    function topUpFloat(address asset, address from, uint256 topUpAmount) external {
        IERC20(asset).safeTransferFrom(from, address(this), topUpAmount);
        _balances[asset] += topUpAmount;
    }

    /// @inheritdoc ISwapper
    function executeSwap(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        bytes memory /* data */
    )
        external
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        // Assumes `amountIn` tokens of `assetIn` were sent from the msg.sender
        uint256 currentBalanceAssetIn = IERC20(assetIn).balanceOf(address(this));

        require(currentBalanceAssetIn >= _balances[assetIn] + amountIn);

        _balances[assetIn] = currentBalanceAssetIn;

        uint256 expectedAmountOut = amountIn.convertAssetDecimals(assetIn, assetOut);

        // This will underflow if there was not enough amount
        _balances[assetOut] -= expectedAmountOut;

        // Approve funds to be pulled by the caller
        IERC20(assetOut).forceApprove(msg.sender, expectedAmountOut);

        return expectedAmountOut;
    }
}
