// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IMintableBurnableIERC20} from "./IMintableBurnableIERC20.sol";

/// @title IIouToken
/// @author Aave Labs
/// @notice Interface for the IOU token.
interface IIouToken is IMintableBurnableIERC20 {
    /// @notice Locks a given amount of IOU tokens by transferring them to the owner of the token contract.
    /// @param from Address of the account to lock the IOU tokens from (tokens are transferred from this address).
    /// @param amount Amount of IOU tokens to lock.
    function lock(address from, uint256 amount) external;
}
