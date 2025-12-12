// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IAcrossSpokePoolV3
/// @notice Interface for the Across Spoke Pool V3 contract.
/// @notice Based on implementation from:
/// https://github.com/across-protocol/contracts/blob/1e1e67f805f8c9d0923e4898959ef243e57792d8/contracts/interfaces/V3SpokePoolInterface.sol#L217
interface IAcrossSpokePoolV3 {
    /// @notice Deposit tokens and message into the Across Spoke Pool V3.
    /// @param depositor The address that is depositing the tokens and message into the Spoke Pool.
    /// @param recipient The address that should receive the funds and message on the destination chain (does not have
    /// to be where the funds ultimately end up on the destination chain).
    /// @param inputToken The token that should be bridged on the source chain.
    /// @param outputToken The token that should be received on the destination chain.
    /// @param inputAmount The amount of the input token to bridge on the source chain.
    /// @param outputAmount The amount of the output token that the recipient should receive on the destination chain.
    /// @param destinationChainId The destination chain ID.
    /// @param exclusiveRelayer The preselected relayer who is given the exclusive right to fill the user (can be
    /// address(0) for public fill).
    /// @param quoteTimestamp The timestamp of the quote (can be block.timestamp).
    /// @param fillDeadline The deadline for the fill to be executed (must be greater than the current block timestamp).
    /// @param exclusivityDeadline The deadline for the exclusive relayer to fill the user's order (can be 0).
    /// @param message The message passed to the recipient on the destination chain through handleV3AcrossMessage(...).
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;
}
