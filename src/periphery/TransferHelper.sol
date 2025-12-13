// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";

/// @title TransferHelper
/// @author Aave Labs
/// @notice Helper contract for transferring assets between non-adjacent contracts, helping to minimize the number of
/// transfers in complex transaction flows.
contract TransferHelper is ITransferHelper {
    using SafeERC20 for IERC20;

    /// @inheritdoc ITransferHelper
    function pull(address[] memory assets, uint256[] memory amounts) external override {
        for (uint256 i = 0; i < assets.length; i++) {
            _transfer(assets[i], amounts[i], msg.sender);
        }
    }

    /// @inheritdoc ITransferHelper
    function pull(address asset, uint256 amount) external override {
        _transfer(asset, amount, msg.sender);
    }

    /// @inheritdoc ITransferHelper
    function transfer(address[] memory assets, uint256[] memory amounts, address destination) external override {
        for (uint256 i = 0; i < assets.length; i++) {
            _transfer(assets[i], amounts[i], destination);
        }
    }

    /// @inheritdoc ITransferHelper
    function transfer(address[] memory assets, uint256[] memory amounts, address[] memory destinations)
        external
        override
    {
        for (uint256 i = 0; i < assets.length; i++) {
            _transfer(assets[i], amounts[i], destinations[i]);
        }
    }

    /// @inheritdoc ITransferHelper
    function transfer(address asset, uint256 amount, address destination) external override {
        _transfer(asset, amount, destination);
    }

    /// @inheritdoc ITransferHelper
    function getBalance(address asset) external view override returns (uint256) {
        if (asset == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(asset).balanceOf(address(this));
        }
    }

    function _transfer(address asset, uint256 amount, address destination) internal {
        if (asset == address(0)) {
            (bool callSucceeded,) = payable(destination).call{value: amount}("");
            require(callSucceeded, ErrorsLib.NativeTransferFailed());
        } else {
            IERC20(asset).safeTransfer(destination, amount);
        }
    }

    receive() external payable {}
}
