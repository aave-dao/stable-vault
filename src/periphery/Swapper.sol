// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ISlippageCoverageVault} from "src/interfaces/ISlippageCoverageVault.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title Swapper
/// @author Aave Labs
/// @notice Swapper contract for executing swaps with slippage coverage and access control.
/// @dev Coverage is pulled from the immutable bound `SLIPPAGE_VAULT`, which also enforces caps and bounds the per-call
/// `slippageToleranceBps` against `maxSlippageBps` (or `overrideMaxSlippageBps` in override mode).
contract Swapper is Ownable, ReentrancyGuardTransient, ISwapper {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    address internal immutable SLIPPAGE_VAULT;

    /// @dev Constructor.
    /// @param allocator Address of the allocator which is the owner of the Swapper.
    /// @param slippageVault Address of the bound SlippageCoverageVault.
    constructor(address allocator, address slippageVault) Ownable(allocator) {
        require(slippageVault != address(0), Errors.ZeroAddress());
        SLIPPAGE_VAULT = slippageVault;
    }

    /// @inheritdoc ISwapper
    /// @dev Assumes `amountIn` tokens of `assetIn` were sent from `msg.sender` (the Allocator) before invocation.
    function executeSwap(address assetIn, address assetOut, uint256 amountIn, address, bytes memory data)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        (address[] memory targets, bytes[] memory callDatas, uint16 slippageToleranceBps) =
            abi.decode(data, (address[], bytes[], uint16));
        require(targets.length == callDatas.length, Errors.InvalidParameter());

        // Bound the slippage tolerance against vault config; read before the loop to fail fast.
        uint16 maxBps = ISlippageCoverageVault(SLIPPAGE_VAULT).getEffectiveMaxSlippageBps();
        require(slippageToleranceBps <= maxBps, ISwapper.SlippageToleranceTooHigh());

        // Targets cannot be the bound vault, otherwise the loop could call `pullCoverage` directly.
        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i] != SLIPPAGE_VAULT, ISwapper.BadTarget());
            (bool callSucceeded,) = targets[i].call(callDatas[i]);
            require(callSucceeded, ISwapper.CallToTargetFailed());
        }

        uint256 amountOut = IERC20(assetOut).balanceOf(address(this));

        // Enforce 1:1 swap between `assetIn` and `assetOut`.
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(assetIn, assetOut);

        if (amountOut < expectedAmountOut) {
            require(
                _minToleratedAmountOut(expectedAmountOut, slippageToleranceBps) <= amountOut,
                ISwapper.SlippageToleranceExceeded()
            );
            uint256 slippageAmount = expectedAmountOut - amountOut;
            ISlippageCoverageVault(SLIPPAGE_VAULT).pullCoverage(assetOut, slippageAmount);
            emit ISwapper.SlippageCovered(SLIPPAGE_VAULT, assetOut, slippageAmount);
            amountOut = expectedAmountOut;
        }

        uint256 leftover = IERC20(assetIn).balanceOf(address(this));
        if (leftover > 0) {
            _reimburseCoverage(assetIn, leftover);
        }

        // Approve `assetOut` funds to be pulled by the msg.sender (the Allocator).
        IERC20(assetOut).forceApprove(msg.sender, amountOut);

        return amountOut;
    }

    /// @inheritdoc ISwapper
    function getSlippageVault() external view override returns (address) {
        return SLIPPAGE_VAULT;
    }

    function _minToleratedAmountOut(uint256 expectedAmountOut, uint16 slippageToleranceBps)
        internal
        pure
        returns (uint256)
    {
        return expectedAmountOut * (Constants.MAX_BPS - slippageToleranceBps) / Constants.MAX_BPS;
    }

    /// @notice Repays the vault for `amount` of `asset` left on the Swapper after a swap.
    /// @dev Leftover `assetIn` happens when the venue doesn't consume the full `amountIn` (RFQ partials,
    /// aggregator routing) or when someone donated to the Swapper beforehand. In the under-consumption case
    /// the slippage check above pulled `assetOut` from the vault to cover what looked like slippage but was
    /// really unconsumed `assetIn`; sending the residual back makes that round trip net to zero (as long as
    /// the two assets are at peg).
    /// @param asset The asset to reimburse.
    /// @param amount The amount to reimburse.
    function _reimburseCoverage(address asset, uint256 amount) internal {
        IERC20(asset).forceApprove(address(SLIPPAGE_VAULT), amount);
        ISlippageCoverageVault(SLIPPAGE_VAULT).returnCoverage(asset, amount);
        emit ISwapper.AssetInSwept(asset, amount);
    }
}
