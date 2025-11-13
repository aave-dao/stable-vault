// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library ConstantsLib {
    /// @dev The token address used to indicate the asset used to pay a bridge fee is the native currency.
    address public constant NATIVE_CURRENCY = address(0);

    /// @dev The token address used in bridging flows when only an arbitrary message is being bridged.
    address internal constant ASSET_FOR_DATA_ONLY_BRIDGE = address(0);

    /// @dev The number of decimals for the RAY denomination.
    uint8 internal constant RAY_DECIMALS = 27;
}
