// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITransferHelper} from "../interfaces/ITransferHelper.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @title TransferHelper
/// @notice Helper contract for transferring assets between non-adjacent contracts, helping to minimize the number of
/// transfers in complex transaction flows.
contract TransferHelper is ITransferHelper {
    using SafeERC20 for IERC20;

    function pull(address[] memory assets, uint256[] memory amounts) external payable override {
        for (uint256 i = 0; i < assets.length; i++) {
            _transfer(assets[i], amounts[i], msg.sender);
        }
    }

    function transfer(address[] memory assets, uint256[] memory amounts, address destination)
        external
        payable
        override
    {
        for (uint256 i = 0; i < assets.length; i++) {
            _transfer(assets[i], amounts[i], destination);
        }
    }

    function transfer(address[] memory assets, uint256[] memory amounts, address[] memory destinations)
        external
        payable
        override
    {
        for (uint256 i = 0; i < assets.length; i++) {
            _transfer(assets[i], amounts[i], destinations[i]);
        }
    }

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
