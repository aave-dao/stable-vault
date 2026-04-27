// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title BridgeParamsCodec
/// @author Aave Labs
/// @notice Shared encode/decode helpers for the opaque `bridgeParamsEncoded` bytes that travel through
/// every bridge-flow entrypoint. Callers (users, scripts, SDK) and tests use `encode` to construct the
/// blob; concrete bridge adapters use `decode` to recover the typed `BridgeParams` struct.
/// @dev The canonical shape is `abi.encode(IBridgeAdapter.BridgeParams)`. No version byte, no
/// discriminator — a second adapter with a different params shape would ship its own codec alongside
/// its own struct definition.
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
