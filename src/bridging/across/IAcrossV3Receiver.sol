// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IAcrossV3Receiver
/// @notice Interface for the Across V3 Receiver contract.
interface IAcrossV3Receiver {
    /// @notice Receive a message from the Across V3 Spoke Pool
    /// @param token Address of the token received.
    /// @param amount Token quantity received.
    /// @param relayer Address of the relayer that invoked the Spoke Pool on the destination chain.
    /// @param message Arbitrary data passed to the recipient on the destination chain (published by the depositor on
    /// the source chain).
    function handleV3AcrossMessage(address token, uint256 amount, address relayer, bytes memory message) external;
}
