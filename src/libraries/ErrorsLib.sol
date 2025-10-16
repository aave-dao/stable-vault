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

    /// @notice Not enough liquidity to cover the withdrawal.
    error InsufficientLiquidity();

    /// @notice Failed to deposit assets into the vault.
    error VaultDepositFailed();

    /// @notice Thrown when input parameter contains unacceptable amount.
    error InvalidAmount();

    /// @notice Address checked is not the self.
    error NotSelf();
}
