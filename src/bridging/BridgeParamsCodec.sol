// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title BridgeParamsCodec
/// @author Aave Labs
/// @notice Helper to encode/decode an adapter's bridge parameters.
/// @dev An adapter requiring a different parameter shape would ship its own codec alongside its struct definition.
library BridgeParamsCodec {
    /// @notice Encodes a `BridgeParams` struct into the opaque bytes shape expected by bridge-flow
    /// entrypoints.
    function encode(IBridgeAdapter.BridgeParams memory params) internal pure returns (bytes memory) {
        return abi.encode(params);
    }

    /// @notice Decodes the opaque bytes produced by `encode` back into a `BridgeParams` struct.
    /// @dev Reverts on malformed / truncated input via Solidity's built-in decoder checks.
    function decode(bytes memory bridgeParamsEncoded) internal pure returns (IBridgeAdapter.BridgeParams memory) {
        return abi.decode(bridgeParamsEncoded, (IBridgeAdapter.BridgeParams));
    }
}
