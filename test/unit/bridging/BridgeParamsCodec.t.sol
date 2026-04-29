// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {BridgeParamsCodec} from "src/bridging/BridgeParamsCodec.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title BridgeParamsCodecTest
/// @notice Regression tests for the opaque-bytes dispatch codec. The codec is the single decoder
/// boundary between the opaque `bridgeParamsEncoded` blob that caller contracts forward and the
/// typed `BridgeParams` struct that the adapter acts on — round-trip and malformed-input behavior
/// are load-bearing invariants.
contract BridgeParamsCodecTest is Test {
    function test_encodeDecodeRoundTrip(
        address feeToken,
        uint256 feeAmount,
        uint256 feeRefundThreshold,
        uint256 gasLimit,
        bytes memory data
    ) public pure {
        IBridgeAdapter.BridgeParams memory original = IBridgeAdapter.BridgeParams({
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: feeRefundThreshold,
            gasLimit: gasLimit,
            data: data
        });

        bytes memory encoded = BridgeParamsCodec.encode(original);
        IBridgeAdapter.BridgeParams memory decoded = BridgeParamsCodec.decode(encoded);

        assertEq(decoded.feeToken, original.feeToken);
        assertEq(decoded.feeAmount, original.feeAmount);
        assertEq(decoded.feeRefundThreshold, original.feeRefundThreshold);
        assertEq(decoded.gasLimit, original.gasLimit);
        assertEq(decoded.data, original.data);
    }

    function test_decodeMalformedBytes_reverts_onEmpty() public {
        bytes memory empty = "";
        vm.expectRevert();
        this.callDecode(empty);
    }

    function test_decodeMalformedBytes_reverts_onTruncated() public {
        // A valid encoding is 5 * 32 bytes (static fields) + dynamic `data` offset + length + bytes.
        // 64 bytes is well below the minimum — Solidity's abi.decode must revert.
        bytes memory truncated = new bytes(64);
        vm.expectRevert();
        this.callDecode(truncated);
    }

    function test_decodeMalformedBytes_reverts_onGarbageWithInvalidDataOffset() public {
        // Construct bytes that look the right size but encode an invalid dynamic-offset pointer
        // for the trailing `bytes data` field — triggers the Solidity decoder's bounds check.
        bytes memory garbage = abi.encode(
            address(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(type(uint256).max) // dynamic offset pointer way out of bounds
        );
        vm.expectRevert();
        this.callDecode(garbage);
    }

    /// @dev Wrapper needed because `vm.expectRevert` does not catch reverts in the same call frame
    /// when the revert happens inside a `pure` internal library call — routing through an external
    /// call ensures the expect-revert cheat code sees the failure.
    function callDecode(bytes calldata encoded) external pure returns (IBridgeAdapter.BridgeParams memory) {
        return BridgeParamsCodec.decode(encoded);
    }
}
