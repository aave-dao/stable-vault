// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title ErrorsLib
/// @author Aave Labs
/// @notice Library for errors shared across contracts.
library ErrorsLib {
    /// @notice Address checked is already whitelisted.
    /// @custom:selector 0x78426ef8
    error AddressAlreadyWhitelisted();

    /// @notice Address checked is not whitelisted.
    /// @custom:selector 0xad7acb47
    error AddressNotWhitelisted();

    /// @notice Asset already supported.
    /// @custom:selector 0x3b6566d0
    error AssetAlreadySupported(address asset);

    /// @notice Insufficient amount due to slippage tolerance being exceeded.
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

    /// @notice Thrown when native currency transfer failed.
    /// @custom:selector 0xf4b3b1bc
    error NativeTransferFailed();

    /// @notice Thrown when input parameter contains unacceptable value.
    error InvalidParameter();

    /// @notice Thrown when caller is not authorized.
    /// @custom:selector 0xea8e4eb5
    error NotAuthorized();

    /// @notice Address checked is not the Cross-chain gateway.
    /// @custom:selector 0xec76af13
    error OnlyGateway();

    /// @notice Address checked is not the contract being called.
    /// @custom:selector 0x14d4a4e8
    error OnlySelf();

    /// @notice Unsupported asset.
    /// @custom:selector 0xee84f40b
    error UnsupportedAsset(address asset);

    /// @notice Token amount checked is zero.
    /// @custom:selector 0x1f2a2005
    error ZeroAmount();
}
