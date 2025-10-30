// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RescuableAssets {
    using SafeERC20 for IERC20;

    /// @dev Rescue tokens stuck on the contract.
    /// @param asset The asset to rescue.
    /// @param amount The amount of the asset to rescue.
    function rescueTokens(address asset, uint256 amount) public virtual {
        // TODO: send to treasury? If so can make this public.
        IERC20(asset).safeTransfer(msg.sender, amount);
    }
}
