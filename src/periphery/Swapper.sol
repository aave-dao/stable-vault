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
/// `slippageToleranceBps` against `maxSlippageBps` (or `overrideMaxSlippageBps` in override mode). Any `assetIn`
/// left on the Swapper after the swap is returned to the same vault.
/// @dev The vault is an operational helper, not a strict on-chain bound: this Swapper drives the coverage flow and the
/// return of leftover `assetIn`, so the vault's caps do not strictly impose the 1:1 invariant on their own.
contract Swapper is Ownable, ReentrancyGuardTransient, ISwapper {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    address internal immutable SLIPPAGE_VAULT;

    /// @notice Emitted when a slippage shortfall on `assetOut` is covered by an external source.
    event SlippageCovered(address indexed slippageCoverageSource, address indexed assetOut, uint256 amount);

    /// @notice Emitted when unconsumed `assetIn` is pushed to an external destination.
    event AssetInSwept(address indexed to, address indexed asset, uint256 amount);

    /// @notice Thrown when a target invariant required by the implementation is violated.
    /// @custom:selector 0x13496fda
    error BadTarget();

    /// @notice Thrown when an implementation-specific subcall fails.
    /// @custom:selector 0x7f1f16cd
    error CallToTargetFailed();

    /// @notice Thrown when the amount of `assetOut` received is below the minimum acceptable amount.
    /// @custom:selector 0x6728a9f6
    error SlippageToleranceExceeded();

    /// @notice Thrown when the requested slippage tolerance exceeds the on-chain bound.
    /// @custom:selector 0x232b3058
    error SlippageToleranceTooHigh();

    /// @dev Constructor.
    /// @param allocator Address of the allocator which is the owner of the Swapper.
    /// @param slippageCoverageSource Address of the bound SlippageCoverageVault.
    constructor(address allocator, address slippageCoverageSource) Ownable(allocator) {
        require(slippageCoverageSource != address(0), Errors.ZeroAddress());
        SLIPPAGE_VAULT = slippageCoverageSource;
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

        // Targets cannot be the bound vault, otherwise the loop could call `pullCoverage` directly.
        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i] != SLIPPAGE_VAULT, BadTarget());
            (bool callSucceeded,) = targets[i].call(callDatas[i]);
            require(callSucceeded, CallToTargetFailed());
        }

        uint256 amountOut = IERC20(assetOut).balanceOf(address(this));

        // Enforce 1:1 swap between `assetIn` and `assetOut`.
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(assetIn, assetOut);

        if (amountOut < expectedAmountOut) {
            // Bound the per-call tolerance against vault config; only relevant when coverage is actually pulled.
            uint16 coverageSlippageMaxBps = ISlippageCoverageVault(SLIPPAGE_VAULT).getEffectiveMaxSlippageBps();
            require(slippageToleranceBps <= coverageSlippageMaxBps, SlippageToleranceTooHigh());
            require(
                _minToleratedAmountOut(expectedAmountOut, slippageToleranceBps) <= amountOut,
                SlippageToleranceExceeded()
            );
            uint256 slippageAmount = expectedAmountOut - amountOut;
            ISlippageCoverageVault(SLIPPAGE_VAULT).pullCoverage(assetOut, slippageAmount);
            emit SlippageCovered(SLIPPAGE_VAULT, assetOut, slippageAmount);
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

    /// @notice Returns the slippage coverage vault bound to this swapper, if any.
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
        ISlippageCoverageVault(SLIPPAGE_VAULT).reimburseCoverage(asset, amount);
        emit AssetInSwept(SLIPPAGE_VAULT, asset, amount);
    }
}
