// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library ErrorsLib {
    /// @notice Address checked is the zero address.
    error ZeroAddress();

    /// @notice Token amount checked is zero.
    error ZeroAmount();

    /// @notice Unsupported asset.
    error UnsupportedAsset(address asset);

    /// @notice Address checked is already whitelisted.
    error AddressAlreadyWhitelisted();

    /// @notice Address checked is not whitelisted.
    error AddressNotWhitelisted();

    /// @notice Address checked is not the admin.
    error NotAdmin();

    /// @notice Address checked is not the manager.
    error NotManager();

    /// @notice Address checked is not the Cross-chain gateway.
    error NotGateway();

    /// @notice Insufficient amount due to slippage tolerance being exceeded.
    error InsufficientAmountOut();

    /// @notice Thrown when unexpected number of assets are received from a source chain.
    error InvalidBridgeAssetsLength();
}
