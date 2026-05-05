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

    /// @notice Thrown when attempting to distrust something (e.g. asset, strategy) that is already distrusted.
    /// @custom:selector 0x1ed3ece1
    error AlreadyDistrusted();

    /// @notice Thrown when attempting to trust something (e.g. asset, strategy) that is already trusted.
    /// @custom:selector 0xab73bb5f
    error AlreadyTrusted();

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

    /// @notice Thrown when destination chain id checked is the same as the current chain id.
    /// @custom:selector 0x90eaaa70
    error InvalidDestinationChainId();

    /// @notice Thrown when a provided gas limit is below the minimum required for safe execution.
    /// @custom:selector 0x98bdb2e0
    error InvalidGasLimit();

    /// @notice Thrown when input parameter contains unacceptable value.
    /// @custom:selector 0x613970e0
    error InvalidParameter();

    /// @notice Thrown when native currency transfer failed.
    /// @custom:selector 0xf4b3b1bc
    error NativeTransferFailed();

    /// @notice Thrown when caller is not authorized.
    /// @custom:selector 0xea8e4eb5
    error NotAuthorized();

    /// @notice Address checked is not the Cross-chain gateway.
    /// @custom:selector 0xec76af13
    error OnlyGateway();

    /// @notice Thrown when an entry-point operation is denied by its configured policy.
    /// @custom:selector 0xf0b3c09f
    error PolicyDenied();

    /// @notice Address checked is not the contract being called.
    /// @custom:selector 0x14d4a4e8
    error OnlySelf();

    /// @notice Unsupported asset.
    /// @custom:selector 0xee84f40b
    error UnsupportedAsset(address asset);

    /// @notice Address checked is the zero address.
    /// @custom:selector 0xd92e233d
    error ZeroAddress();

    /// @notice Token amount checked is zero.
    /// @custom:selector 0x1f2a2005
    error ZeroAmount();
}
