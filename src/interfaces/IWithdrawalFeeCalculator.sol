// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IWithdrawalFeeCalculator
/// @author Aave Labs
/// @notice Interface for the WithdrawalFeeCalculator contract.
interface IWithdrawalFeeCalculator {
    /// @notice The configuration for an asset-specific fee.
    /// @param feeBps The fee in basis points.
    /// @param isSet Whether the fee is set.
    struct AssetFeeBpsConfig {
        uint16 feeBps; // TODO: Remember which order these need to be and if that matters for further storage extension.
        bool isSet;
    }

    /// @notice Returns the configuration for an asset-specific fee.
    /// @param asset Address of the asset to get the configuration for.
    function getAssetFeeBpsConfig(address asset) external view returns (AssetFeeBpsConfig memory);

    /// @notice Returns the basic fee in basis points.
    function getBasicFeeBps() external view returns (uint256);

    /// @notice Returns whether a signer is whitelisted.
    /// @param signer Address of the signer to check.
    function isSigner(address signer) external view returns (bool);

    /// @notice Calculates the withdrawal fee based on personal fees, asset-specific fees, and basic fees.
    /// @notice Returns the withdrawal fee that should be deducted from the IOU tokens being exchanged for assets.
    /// @param user Address of the user withdrawing the IOU tokens.
    /// @param assetOut Address of the asset to withdraw the IOU tokens to.
    /// @param iouAmountRay Amount of IOU tokens to withdraw.
    /// @param data Custom data required by the withdrawal fee calculator.
    /// @return The withdrawal fee.
    function calculateWithdrawalFee(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        returns (uint256);

    /// @notice Sets the configuration for an asset-specific fee.
    /// @param asset Address of the asset to set the configuration for.
    /// @param newAssetFeeBps The fee in basis points.
    /// @param isSet Whether the fee is set.
    function setAssetFeeBps(address asset, uint256 newAssetFeeBps, bool isSet) external;

    /// @notice Sets the basic (default) flat fee in basis points.
    /// @param newBasicFeeBps The fee in basis points.
    function setBasicFeeBps(uint256 newBasicFeeBps) external;

    /// @notice Sets whether a signer is whitelisted.
    /// @param signer Address of the signer to set.
    /// @param whitelistedSigner Whether the signer is whitelisted.
    function setSigner(address signer, bool whitelistedSigner) external;
}
