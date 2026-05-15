// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ISlippageCoverageVault
/// @author Aave Labs
/// @notice Interface for the SlippageCoverageVault contract.
// TODO: Remove non-essential declarations, avoid coupling the interface to the canonical implementation of it
/// @dev Push-based outflows to the immutable `SLIPPAGE_BENEFICIARY`; the vault never grants ERC-20 allowances. The
/// vault can be deployed in override mode (constructor flag) so the bound Swapper can pull coverage on day one
/// without per-tx or window caps configured; operator flips override off and configures caps once risk-team has
/// set the production targets.
interface ISlippageCoverageVault {
    /// @notice Fixed-window cap state for an asset.
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
    event WindowCapLowered(address indexed asset, uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the window cap for an asset is raised.
    event WindowCapRaised(address indexed asset, uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the window length (in seconds) for an asset is lowered.
    event WindowSecondsLowered(address indexed asset, uint64 oldWindowSeconds, uint64 newWindowSeconds);

    /// @notice Emitted when the window length (in seconds) for an asset is raised.
    event WindowSecondsRaised(address indexed asset, uint64 oldWindowSeconds, uint64 newWindowSeconds);

    /// @notice Thrown when an `enableOverrideMode` call is made while override mode is already enabled.
    /// @custom:selector 0xf2a5f75a
    error AlreadyEnabled();

    /// @notice Thrown when a `disableOverrideMode` call is made while override mode is already disabled.
    /// @custom:selector 0x005ecddb
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
    /// @dev Rate-limit roles. `pullCapPerTx` is a **per-call ceiling** — a fixed upper bound on a single pull that
    /// does not scale with `amountIn`. It catches operator typos and single-burst attacks; chunking across calls
    /// can still drain up to `windowCap` per `windowSeconds`. `windowCap` + `windowSeconds` are the **actual rate
    /// limit** that bounds sustained drainage (with the documented `2 × cap` boundary burst). See
    /// `raiseWindowCap` for the boundary-burst math.
    /// @param asset The asset to pull.
    /// @param amount The amount to pull.
    function pullCoverage(address asset, uint256 amount) external;

    /// @notice Enables override mode. While enabled, `pullCoverage` bypasses both per-tx and window caps and the
    /// Swapper accepts the higher `overrideMaxSlippageBps`.
    /// @dev Gated by the CoverageGuardian role (separate from the rebalancer, expected to be an N-of-M multisig).
    /// No on-chain delay; compromise resistance is structural (quorum), not temporal. Reverts with `AlreadyEnabled`
    /// if already on.
    function enableOverrideMode() external;

    /// @notice Disables override mode and restores per-tx + window cap enforcement and `maxSlippageBps`.
    /// @dev Gated by the CoverageGuardian role with no delay so tightening is instant. Reverts with `AlreadyDisabled`
    /// if already off.
    function disableOverrideMode() external;

    /// @notice Raises the per-tx cap for an asset. Reverts if `newCap <= current`.
    function raisePullCapPerTx(address asset, uint256 newCap) external;

    /// @notice Lowers the per-tx cap for an asset. Reverts if `newCap >= current`.
    function lowerPullCapPerTx(address asset, uint256 newCap) external;

    /// @notice Raises the window cap for an asset. Reverts if `newCap <= current`. Preserves `windowSeconds`.
    /// @dev Boundary burst: under a fixed-window with lazy rollover, a caller can drain `newCap` at
    /// `t = windowStart + windowSeconds - 1` and another full `newCap` at `t = windowStart + windowSeconds`, for
    /// `2 * newCap` across a ~1-second span. Size `newCap` such that `2 * newCap` is an acceptable dollar exposure
    /// within `windowSeconds`.
    function raiseWindowCap(address asset, uint256 newCap) external;

    /// @notice Lowers the window cap for an asset. Reverts if `newCap >= current`. Preserves `windowSeconds`.
    function lowerWindowCap(address asset, uint256 newCap) external;

    /// @notice Raises the window length (in seconds) for an asset, lengthening the window.
    /// @dev Counter-intuitive risk direction: raising `windowSeconds` SLOWS the drain rate (same cap, more time)
    /// and is therefore a **tightening** action, gated on the operational/no-delay path. Reverts if
    /// `newWindowSeconds <= current`. Preserves `cap`. Boundary burst is `2 * cap` per `windowSeconds`; see
    /// `raiseWindowCap`.
    function raiseWindowSeconds(address asset, uint64 newWindowSeconds) external;

    /// @notice Lowers the window length (in seconds) for an asset, shortening the window.
    /// @dev Counter-intuitive risk direction: lowering `windowSeconds` SPEEDS UP the drain rate (same cap, less
    /// time) and is therefore a **loosening** action, gated on the admin/high-delay path. Reverts if
    /// `newWindowSeconds >= current`. Preserves `cap`.
    function lowerWindowSeconds(address asset, uint64 newWindowSeconds) external;

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
