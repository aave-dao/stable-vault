// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title Constants
/// @author Aave Labs
/// @notice Library for constants shared across contracts.
library Constants {
    /// @dev The base number of basis points.
    uint256 internal constant MAX_BPS = 100_00;

    /// @dev The token address used to indicate the asset used to pay a bridge fee is the native currency.
    address public constant NATIVE_CURRENCY = address(0);

    /// @dev The token address used in bridging flows when only data is being bridged (no asset).
    address internal constant ASSET_FOR_DATA_ONLY_BRIDGE = address(0);

    /// @dev The number of decimals for the RAY denomination.
    uint8 internal constant RAY_DECIMALS = 27;

    /// @dev Maximum number of decimals for a token supported by the system.
    uint8 internal constant MAX_SUPPORTED_ASSET_DECIMALS = 18;

    /// @dev The threshold for the smallest withdrawable amount in RAY for the maximum supported token decimals (18)
    /// which is enforced in AssetRegistry.
    /// @dev 10^(RAY_DECIMALS - MAX_SUPPORTED_ASSET_DECIMALS) = 10^(27-18) = 1e9.
    uint256 internal constant MIN_WITHDRAWABLE_AMOUNT_RAY = 1e9;

    /// @dev The length of an ABI-encoded EVM address in bytes.
    uint256 internal constant ABI_ENCODED_EVM_ADDRESS_BYTE_LENGTH = 32;

    /// @dev The mask for the ABI-encoded EVM address.
    bytes32 internal constant ABI_ENCODED_EVM_ADDRESS_MASK =
        0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
}
