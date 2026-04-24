// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title IIouTokenManager
/// @author Aave Labs
/// @notice Interface for the IOU token manager.
interface IIouTokenManager {
    event TokensBridged(
        uint256 indexed destinationChainId, address indexed iouTokenRecipient, uint256 iouTokenAmountRay
    );

    event LockedTokensReleased(address indexed to, uint256 amountRay);

    event LockedTokensBurned(address indexed from, uint256 amountRay);

    event TokensLocked(address indexed from, uint256 amountRay);

    /// @notice Thrown when the amount of locked tokens is insufficient to burn or release.
    /// @custom:selector 0xb646ec7b
    error InsufficientLockedBalance();

    /// @notice Thrown when a function that should only be invoked on the Accounting chain is invoked on an Earning
    /// chain.
    /// @custom:selector 0x4f0475a7
    error OnlyAccountingChain();

    /// @notice Getter for the address of the IOU token.
    /// @return asset Address of the IOU token.
    function getAsset() external view returns (address);

    /// @notice Getter for the locked balance of the IOU token which has been bridged to Earning Chain(s).
    /// @dev Locked IOU tokens sit in the contract until they are burned due to an asset exchange on an Earning Chain or
    /// bridged back to the Accounting Chain.
    /// @dev This function should return 0 on Earning Chains as IOU tokens are not
    /// locked on Earning Chains.
    /// @return lockedBalance Locked balance of the IOU token.
    function getLockedBalance() external view returns (uint256);

    /// @notice Entry point for IOU token owners to bridge tokens to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param iouTokenRecipient The address to send the IOU tokens to on the destination chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to bridge.
    /// @param adapter The whitelisted bridge adapter to use for the message.
    /// @param bridgeParams The parameters for the bridge adapter.
    function bridgeTokens(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        address adapter,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable;

    /// @notice Mints tokens and transfers them to the caller (assumes this contract has mint privileges on the IOU
    /// token).
    /// @param to Address to mint the tokens to.
    /// @param amount Amount of tokens to mint.
    function mintTokens(address to, uint256 amount) external;

    /// @notice Burns tokens from the specified address (assumes this contract has burn privileges on the IOU token).
    /// @param from Address to burn the tokens from.
    /// @param amount Amount of tokens to burn.
    function burnTokens(address from, uint256 amount) external;

    /// @notice Burns locked tokens.
    /// @dev This is used only on the Accounting chain because tokens are only locked when bridging to an Earning chain.
    /// @param amount Amount of locked tokens to burn.
    function burnLockedTokens(uint256 amount) external;

    /// @notice Unlocks tokens and transfers them to the caller.
    /// @dev This is used if IOU tokens are bridged back to the Accounting chain.
    /// @param to Address to send the unlocked IOU tokens to.
    /// @param amount Amount of IOU tokens to release.
    function releaseTokens(address to, uint256 amount) external;
}
