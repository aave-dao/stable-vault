// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransferHelper} from "../../src/common/TransferHelper.sol";
import {ITransferHelper} from "../../src/interfaces/ITransferHelper.sol";
import {IMockErc20} from "./MockErc20.sol";

contract MockTransferHelper is ITransferHelper, TransferHelper {
    function mockAsset(address asset, uint256 amount) external {
        IMockErc20(asset).mint(address(this), amount);
    }
}
