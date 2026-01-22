// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title Errors
/// @author Aave Labs
/// @notice Library for errors shared across contracts.
library Errors {
    /// @notice Address checked is already whitelisted.
    /// @custom:selector 0x78426ef8
    error AddressAlreadyWhitelisted();

    /// @notice Address checked is not whitelisted.
    /// @custom:selector 0xad7acb47
    error AddressNotWhitelisted();

    /// @notice Asset already supported.
    /// @custom:selector 0x3b6566d0
    error AssetAlreadySupported(address asset);

    /// @notice Insufficient amount due to slippage/fee tolerance being exceeded.
    /// @custom:selector 0xe52970aa
    error InsufficientAmountOut();

    /// @notice Insufficient funds.
    /// @custom:selector 0x356680b7
    error InsufficientFunds();

    /// @notice Thrown when input parameter contains unacceptable amount.
    /// @custom:selector 0x2c5211c6
    error InvalidAmount();

    /// @notice Thrown when input parameter contains unacceptable asset.
    /// @custom:selector 0x6f79c78a
    error InvalidAsset(address asset);

    /// @notice Thrown when bridge fee payer is not the expected caller.
    /// @custom:selector 0xecec4b20
    error InvalidBridgeFeePayer();

    /// @notice Thrown when destination chain id checked is the same as the current chain id.
    /// @custom:selector 0x90eaaa70
    error InvalidDestinationChainId();

    /// @notice Thrown when input parameter contains unacceptable value.
    /// @custom:selector 0x613970e0
    error InvalidParameter();

    /// @notice Thrown when a price obtained from an oracle for an asset is invalid.
    /// @custom:selector 0x00bfc921
    error InvalidPrice();

    /// @notice Thrown when a recovered signer is not a whitelisted signer.
    /// @custom:selector 0x8baa579f
    error InvalidSignature();

    /// @notice Thrown when native currency transfer failed.
    /// @custom:selector 0xf4b3b1bc
    error NativeTransferFailed();

    /// @notice Thrown when caller is not authorized.
    /// @custom:selector 0xea8e4eb5
    error NotAuthorized();

    /// @notice Address checked is not the Cross-chain gateway.
    /// @custom:selector 0xec76af13
    error OnlyGateway();

    /// @notice Address checked is not the contract being called.
    /// @custom:selector 0x14d4a4e8
    error OnlySelf();

    /// @notice Thrown when a signature nonce has already been used.
    /// @custom:selector 0x85127399
    error SignatureNonceAlreadyConsumed(address signer, uint256 nonce);

    /// @notice Thrown when a signature timestamp has expired.
    /// @custom:selector 0x2eac42fc
    error SignatureTimestampExpired();

    /// @notice Thrown when a price obtained from an oracle for an asset was updated before a threshold timestamp.
    /// @custom:selector 0x19abf40e
    error StalePrice();

    /// @notice Unsupported asset.
    /// @custom:selector 0xee84f40b
    error UnsupportedAsset(address asset);

    /// @notice Token amount checked is zero.
    /// @custom:selector 0x1f2a2005
    error ZeroAmount();
}
