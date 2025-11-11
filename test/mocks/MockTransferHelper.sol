// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransferHelper} from "../../src/common/TransferHelper.sol";
import {ITransferHelper} from "../../src/interfaces/ITransferHelper.sol";
import {IMockErc20} from "./MockErc20.sol";

contract MockTransferHelper is ITransferHelper, TransferHelper {

    function mockAsset(address asset, uint256 amount) external {
        IMockErc20(asset).mint(address(this), amount);
    }

    function mockAssetBalance(address asset, uint256 balance) external {
        uint256 currentBalance = IMockErc20(asset).balanceOf(address(this));
        if (currentBalance < balance ) {
            IMockErc20(asset).mint(address(this), balance - currentBalance);
        } else if (currentBalance > balance) {
            IMockErc20(asset).burn(address(this), currentBalance - balance);
        }
    }

    function mockNativeOutboundToReachBalanceOf(uint256 desiredBalanceAfterOutbound) external {
        uint256 currentBalance = address(this).balance;
        if (currentBalance < desiredBalanceAfterOutbound) {
            payable(address(0)).transfer(desiredBalanceAfterOutbound - currentBalance);
        } else if (currentBalance > desiredBalanceAfterOutbound) {
            payable(address(0)).transfer(currentBalance - desiredBalanceAfterOutbound);
        }
    }
}
