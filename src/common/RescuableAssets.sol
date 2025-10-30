// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRescuableAssets} from "../interfaces/IRescuableAssets.sol";

contract RescuableAssets is IRescuableAssets {
    using SafeERC20 for IERC20;

    function rescueTokens(address asset, uint256 amount) public virtual override {
        // TODO: send to treasury? If so can make this public.
        IERC20(asset).safeTransfer(msg.sender, amount);
    }
}
