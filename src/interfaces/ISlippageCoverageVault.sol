// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ISlippageCoverageVault
/// @author Aave Labs
/// @notice Interface for the SlippageCoverageVault contract.
/// @dev Push-based outflows to the immutable `SLIPPAGE_BENEFICIARY`; the vault never grants ERC-20 allowances. The
/// vault can be deployed in override mode (constructor flag) so the bound Swapper can pull coverage on day one
/// without per-tx or window caps configured; governance flips override off and configures caps once risk-team has
/// set the production targets.
interface ISlippageCoverageVault {
    /// @notice Sliding-window cap state for an asset.
    /// @param windowStart Timestamp at which the current window started.
    /// @param windowSeconds Length of the window in seconds.
    /// @param consumed Amount consumed within the current window.
    /// @param cap Maximum amount that can be consumed within a single window.
    struct Window {
        uint64 windowStart;
        uint64 windowSeconds;
        uint128 consumed;
        uint128 cap;
    }

    /// @notice Emitted when the vault is funded.
    event CoverageFunded(address indexed asset, address indexed from, uint256 amount);

    /// @notice Emitted when coverage is pulled by the bound beneficiary.
    event CoveragePulled(address indexed asset, uint256 amount, bool overrideMode);

    /// @notice Emitted when the normal-mode max slippage tolerance is set.
    event MaxSlippageBpsSet(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the override-mode max slippage tolerance is set.
    event OverrideMaxSlippageBpsSet(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when override mode is toggled.
    event OverrideModeSet(bool enabled);

    /// @notice Emitted when the per-tx cap for an asset is lowered.
    event PullCapPerTxLowered(address indexed asset, uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the per-tx cap for an asset is raised.
    event PullCapPerTxRaised(address indexed asset, uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the vault is swept.
    event Swept(address indexed asset, address indexed to, uint256 amount);

    /// @notice Emitted when the window cap for an asset is lowered.
    event WindowCapLowered(address indexed asset, uint256 oldCap, uint256 newCap, uint64 windowSeconds);

    /// @notice Emitted when the window cap for an asset is raised.
    event WindowCapRaised(address indexed asset, uint256 oldCap, uint256 newCap, uint64 windowSeconds);

    /// @notice Thrown when an `enableOverrideMode` call is made while override mode is already enabled.
    error AlreadyEnabled();

    /// @notice Thrown when a `disableOverrideMode` call is made while override mode is already disabled.
    error AlreadyDisabled();

    /// @notice Thrown when a single pull would exceed the per-tx cap for the asset.
    /// @custom:selector 0x49aeece1
    error ExceedsPerTxCap();

    /// @notice Thrown when a pull would exceed the cumulative window cap for the asset, or the window is unconfigured.
    /// @custom:selector 0x21ff5759
    error ExceedsWindowCap();

    /// @notice Thrown when the caller of a beneficiary-gated function is not the immutable bound beneficiary.
    /// @custom:selector 0x5e5a9749
    error OnlyBeneficiary();

    /// @notice Pulls `amount` of `asset` from the vault to the bound beneficiary.
    /// @dev Callable only by `SLIPPAGE_BENEFICIARY`. Bypasses caps in override mode. Updates window state before the
    /// transfer.
    /// @param asset The asset to pull.
    /// @param amount The amount to pull.
    function pullCoverage(address asset, uint256 amount) external;

    /// @notice Enables override mode. While enabled, `pullCoverage` bypasses both per-tx and window caps and the
    /// Swapper accepts the higher `overrideMaxSlippageBps`.
    /// @dev Gated by a role separate from the rebalancer (CoverageGuardian) with a scheduling delay so the loosening
    /// has a public, cancellable window. Reverts with `AlreadyEnabled` if already on.
    function enableOverrideMode() external;

    /// @notice Disables override mode and restores per-tx + window cap enforcement and `maxSlippageBps`.
    /// @dev Gated by the CoverageGuardian role with no delay so tightening is instant. Reverts with `AlreadyDisabled`
    /// if already off.
    function disableOverrideMode() external;

    /// @notice Raises the per-tx cap for an asset. Reverts if `newCap <= current`.
    function raisePullCapPerTx(address asset, uint256 newCap) external;

    /// @notice Lowers the per-tx cap for an asset. Reverts if `newCap >= current`.
    function lowerPullCapPerTx(address asset, uint256 newCap) external;

    /// @notice Raises the window cap for an asset. Reverts if `newCap <= current` or `windowSeconds == 0`.
    /// @dev `windowSeconds` always replaces the current window length, regardless of direction.
    function raiseWindowCap(address asset, uint256 newCap, uint64 windowSeconds) external;

    /// @notice Lowers the window cap for an asset. Reverts if `newCap >= current` or `windowSeconds == 0`.
    function lowerWindowCap(address asset, uint256 newCap, uint64 windowSeconds) external;

    /// @notice Sets the normal-mode max slippage tolerance in basis points.
    function setMaxSlippageBps(uint16 newBps) external;

    /// @notice Sets the override-mode max slippage tolerance in basis points.
    function setOverrideMaxSlippageBps(uint16 newBps) external;

    /// @notice Funds the vault with `amount` of `asset`. Pulls from the caller via `safeTransferFrom`.
    function fundCoverage(address asset, uint256 amount) external;

    /// @notice Sweeps `amount` of `asset` from the vault to `to`.
    function sweep(address asset, uint256 amount, address to) external;

    /// @notice Getter for the immutable bound beneficiary (the Swapper).
    function getBeneficiary() external view returns (address);

    /// @notice Getter for whether override mode is enabled.
    function getOverrideMode() external view returns (bool);

    /// @notice Getter for the per-tx cap for an asset.
    function getPullCapPerTx(address asset) external view returns (uint256);

    /// @notice Getter for the window state for an asset.
    function getWindow(address asset) external view returns (Window memory);

    /// @notice Getter for the normal-mode max slippage tolerance.
    function getMaxSlippageBps() external view returns (uint16);

    /// @notice Getter for the override-mode max slippage tolerance.
    function getOverrideMaxSlippageBps() external view returns (uint16);

    /// @notice Max slippage tolerance currently in effect: `overrideMaxSlippageBps` if override mode is enabled,
    /// otherwise `maxSlippageBps`.
    function getEffectiveMaxSlippageBps() external view returns (uint16);
}
