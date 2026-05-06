// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title BridgeParamsCodec
/// @author Aave Labs
/// @notice Helper to encode/decode an adapter's bridge parameters.
/// @dev An adapter requiring a different parameter shape would ship its own codec alongside its struct definition.
library BridgeParamsCodec {
    /// @notice The parameters for the bridge adapter.
    /// @dev `feePayer` is intentionally not part of this struct; it is propagated as an explicit calldata
    /// parameter set by the trusted entry-point to its `msg.sender`. A blob-supplied `feePayer` would let
    /// any caller of any bridge entry-point drain a non-zero ERC20 approval to the adapter.
    /// @param feeToken Token to pay the bridge fee in.
    /// @param feeAmount Amount of `feeToken` approved by `feePayer` to spend on fees.
    /// @param feeRefundThreshold Minimum amount of `feeToken` that must remain unused in order to trigger a refund to
    /// the `feePayer`.
    /// @param data Arbitrary data that may be required by the bridge adapter to operate.
    struct BridgeParams {
        address feeToken;
        uint256 feeAmount;
        uint256 feeRefundThreshold;
        bytes data;
    }

    /// @notice Encodes a `BridgeParams` struct into the opaque bytes shape expected by bridge-flow entrypoints.
    function encode(BridgeParams memory params) internal pure returns (bytes memory) {
        return abi.encode(params);
    }

    /// @notice Decodes the opaque bytes produced by `encode` back into a `BridgeParams` struct.
    function decode(bytes memory bridgeParamsEncoded) internal pure returns (BridgeParams memory) {
        return abi.decode(bridgeParamsEncoded, (BridgeParams));
    }
}
