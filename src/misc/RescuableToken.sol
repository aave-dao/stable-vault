// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {Errors} from "src/types/Errors.sol";

/// @title RescuableToken
/// @author Aave Labs
/// @notice Abstract base contract for contracts that can rescue tokens.
abstract contract RescuableToken is IRescuableToken {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRescuableToken
    function rescueTokens(address token, uint256 amount) public virtual override {
        _beforeRescueTokens(token, amount);
        if (token == address(0)) {
            revert Errors.InvalidAsset(token);
        }
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function _beforeRescueTokens(address token, uint256 amount) internal virtual;
}
