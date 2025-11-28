// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRescuableAssets} from "src/interfaces/IRescuableAssets.sol";

/// @title RescuableAssets
/// @author Aave Labs
/// @notice Abstract base contract for contracts that can rescue tokens.
contract RescuableAssets is IRescuableAssets {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRescuableAssets
    function rescueTokens(address asset, uint256 amount) public virtual override {
        IERC20(asset).safeTransfer(msg.sender, amount);
    }
}
