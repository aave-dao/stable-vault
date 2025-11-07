// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library ErrorsLib {
    /// @notice Address checked is the zero address.
    error ZeroAddress();

    /// @notice Chain id checked is zero.
    error ZeroChainId();

    /// @notice Token amount checked is zero.
    error ZeroAmount();

    /// @notice Thrown when destination chain id checked is the same as the current chain id.
    error InvalidDestinationChainId();

    /// @notice Unsupported asset.
    error UnsupportedAsset(address asset);

    /// @notice Asset already supported.
    error AssetAlreadySupported(address asset);

    /// @notice Address checked is already whitelisted.
    error AddressAlreadyWhitelisted();

    /// @notice Address checked is not whitelisted.
    error AddressNotWhitelisted();

    /// @notice Address checked is not the Cross-chain gateway.
    error NotGateway();

    /// @notice Address checked is not message sender.
    error InvalidMessageSender();

    /// @notice Address checked is not the destination chain adapter.
    error NotDestinationChainAdapter();

    /// @notice Insufficient amount due to slippage tolerance being exceeded.
    error InsufficientAmountOut();

    /// @notice Insufficient funds.
    error InsufficientFunds();

    /// @notice Thrown when input parameter contains unacceptable amount.
    error InvalidAmount();

    /// @notice Thrown when input parameter contains unacceptable asset.
    error InvalidAsset(address asset);

    /// @notice Address checked is not the self.
    error NotSelf();

    /// @notice Thrown when input parameter contains unacceptable length.
    error InvalidLength();

    /// @notice Thrown when caller is not authorized.
    error NotAuthorized();
}
