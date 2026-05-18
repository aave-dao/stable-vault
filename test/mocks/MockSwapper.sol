// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "src/interfaces/ISwapper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";

contract MockSwapper is ISwapper {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    bool internal _mockSlippage;

    function mockSlippage(bool slippage) external {
        _mockSlippage = slippage;
    }

    /// @inheritdoc ISwapper
    function executeSwap(address assetIn, address assetOut, uint256 amountIn, address, bytes memory)
        external
        override
        returns (uint256)
    {
        uint256 amountOut = amountIn.convertAssetDecimals(assetIn, assetOut);
        if (_mockSlippage) {
            amountOut -= 1;
        }

        // assetOut should be minted/transferred to this contract during test execution
        IERC20(assetOut).forceApprove(msg.sender, amountOut);
        return amountOut;
    }
}
