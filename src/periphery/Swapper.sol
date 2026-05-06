// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISlippageCoverageVault} from "src/interfaces/ISlippageCoverageVault.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title Swapper
/// @author Aave Labs
/// @notice Swapper contract for executing swaps with slippage coverage and access control.
/// @dev Coverage funds are pulled from the immutable bound `SLIPPAGE_VAULT` via `pullCoverage`. The vault enforces
/// per-tx + sliding-window caps and bounds the manager's per-call slippage tolerance against governance-tunable
/// `maxSlippageBps` (or `overrideMaxSlippageBps` in override mode).
contract Swapper is Ownable, ReentrancyGuard, ISwapper {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    /// @dev The immutable bound vault. Set at construction; rotation requires Swapper redeploy + AccessManager re-wire.
    address internal immutable SLIPPAGE_VAULT;

    /// @dev Constructor.
    /// @param allocator Address of the allocator which is the owner of the Swapper.
    /// @param slippageVault Address of the bound SlippageCoverageVault.
    constructor(address allocator, address slippageVault) Ownable(allocator) {
        require(allocator != address(0), Errors.ZeroAddress());
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

        // Hardening 2 (fail fast): slippage tolerance is bounded against governance-tunable bounds on the vault.
        // Reads the vault's bounds before the target loop so a tolerance abuse reverts cheaply, regardless of what
        // the loop does.
        uint16 maxBps = ISlippageCoverageVault(SLIPPAGE_VAULT).getOverrideMode()
            ? ISlippageCoverageVault(SLIPPAGE_VAULT).getOverrideMaxSlippageBps()
            : ISlippageCoverageVault(SLIPPAGE_VAULT).getMaxSlippageBps();
        require(slippageToleranceBps <= maxBps, ISwapper.SlippageToleranceTooHigh());

        // Hardening 1: targets cannot be the bound vault. Without this, manager could craft
        // `targets[i] = vault, callDatas[i] = pullCoverage(...)` — msg.sender at the vault would be the Swapper
        // (the bound recipient), so the loop would bypass the slippage cap entirely.
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

        // Hardening 3: assetIn must be fully consumed by the call loop. Closes the assetIn-redirection attack —
        // manager redirects `amountIn` to attacker EOA inside the loop while coverage funds `assetOut`; without this,
        // the Allocator's 1:1 invariant on `assetOut` doesn't catch it.
        require(IERC20(assetIn).balanceOf(address(this)) == 0, ISwapper.AssetInLeftOver());

        // Approve funds to be pulled by the caller i.e. the owner of the Swapper.
        IERC20(assetOut).forceApprove(msg.sender, amountOut);

        return amountOut;
    }

    /// @notice Getter for the immutable bound vault.
    function getSlippageVault() external view returns (address) {
        return SLIPPAGE_VAULT;
    }

    function _minToleratedAmountOut(uint256 expectedAmountOut, uint16 slippageToleranceBps)
        internal
        pure
        returns (uint256)
    {
        return expectedAmountOut * (Constants.MAX_BPS - slippageToleranceBps) / Constants.MAX_BPS;
    }
}
