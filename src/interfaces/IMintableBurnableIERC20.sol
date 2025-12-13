// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IMintableBurnableIERC20
/// @author Aave Labs
/// @notice Interface for a mintable and burnable ERC20 token.
interface IMintableBurnableIERC20 is IERC20 {
    /// @notice Mints a given amount of tokens to a given address.
    /// @param to Address to mint the tokens to.
    /// @param amount Amount of tokens to mint.
    function mint(address to, uint256 amount) external;

    /// @notice Burns a given amount of tokens from a given address.
    /// @dev Burning tokens reduces the total supply of the token.
    /// @param from Address to burn the tokens from.
    /// @param amount Amount of tokens to burn.
    function burn(address from, uint256 amount) external;
}
