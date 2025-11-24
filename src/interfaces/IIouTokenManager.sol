// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IChainGateway} from "./IChainGateway.sol";

interface IIouTokenManager {
    error InsufficientLockedBalance();
    error NotAccountingChain();

    /// @return address of the IOU token.
    function getAsset() external view returns (address);

    /// @return the locked balance of the IOU token.
    function getLockedBalance() external view returns (uint256);

    /// @notice Entry point for IOU token owners to bridge tokens to a destination chain.
    /// @dev Pulls tokens from caller and holds them in the contract until unlock is called.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param iouTokenRecipient The address to send the IOU tokens to on the destination chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to bridge.
    /// @param bridgeParams The parameters for the bridge adapter.
    function bridgeTokens(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        IChainGateway.BridgeParams memory bridgeParams
    ) external payable;

    /// @notice Mints tokens and transfers them to the caller (assumes this contract has mint privileges on the IOU
    /// token).
    function mintTokens(address to, uint256 amount) external;

    /// @notice Burns tokens and transfers them to the caller (assumes this contract has burn privileges on the IOU
    /// token).
    function burnTokens(address from, uint256 amount) external;

    /// @notice Burns locked tokens.
    function burnLockedTokens(uint256 amount) external;

    /// @notice Unlocks tokens and transfers them to the caller.
    /// @dev This is used if IOU tokens are bridged back to the Accounting chain.
    /// @param to The address to send the unlocked IOU tokens to.
    /// @param amount The amount of IOU tokens to release.
    function releaseTokens(address to, uint256 amount) external;
}
