// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library ErrorsLib {
    /// @notice Address checked is the zero address.
    error ZeroAddress();

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
}
