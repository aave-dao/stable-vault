// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISwapper} from "src/interfaces/ISwapper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {ConstantsLib} from "src/libraries/ConstantsLib.sol";

/// @title Swapper
/// @author Aave Labs
/// @notice Swapper contract for executing swaps with slippage & access control.
contract Swapper is Ownable, ReentrancyGuard, ISwapper {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    /// @dev Constructor.
    /// @param allocator Address of the allocator which is the owner of the Swapper.
    constructor(address allocator) Ownable(allocator) {}

    /// @notice The parameters for the slippage tolerance.
    /// @param slippageToleranceBps The slippage tolerance in basis points.
    /// @param slippageCoverageSource The account which must approve the Swapper to pull `assetOut` to cover slippage,
    /// fees, etc.
    struct SlippageParams {
        uint16 slippageToleranceBps;
        address slippageCoverageSource;
    }

    /// @inheritdoc ISwapper
    /// @dev Assumes `amountIn` tokens of `assetIn` were sent from the msg.sender
    function executeSwap(address assetIn, address assetOut, uint256 amountIn, bytes memory data)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        (address[] memory targets, bytes[] memory callDatas, SlippageParams memory slippageParams) =
            abi.decode(data, (address[], bytes[], SlippageParams));

        for (uint256 i = 0; i < targets.length; i++) {
            (bool callSucceeded,) = targets[i].call(callDatas[i]);
            require(callSucceeded, ISwapper.CallToTargetFailed());
        }

        uint256 amountOut = IERC20(assetOut).balanceOf(address(this));

        // Enforce 1:1 swap between `assetIn` and `assetOut`.
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(assetIn, assetOut);

        if (amountOut < expectedAmountOut) {
            require(
                _minToleratedAmountOut(expectedAmountOut, slippageParams.slippageToleranceBps) <= amountOut,
                ISwapper.SlippageToleranceExceeded()
            );
            uint256 slippageAmount = expectedAmountOut - amountOut;
            IERC20(assetOut).safeTransferFrom(slippageParams.slippageCoverageSource, address(this), slippageAmount);
            amountOut = expectedAmountOut;
        }

        // Approve funds to be pulled by the caller i.e. the owner of the Swapper.
        IERC20(assetOut).forceApprove(msg.sender, amountOut);

        return amountOut;
    }

    function _minToleratedAmountOut(uint256 expectedAmountOut, uint16 slippageToleranceBps)
        internal
        pure
        returns (uint256)
    {
        return expectedAmountOut * (ConstantsLib.MAX_BPS - slippageToleranceBps) / ConstantsLib.MAX_BPS;
    }
}
