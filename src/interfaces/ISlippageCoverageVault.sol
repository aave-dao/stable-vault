// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title ISlippageCoverageVault
/// @author Aave Labs
/// @notice Interface for the SlippageCoverageVault contract.
/// @dev Push-based outflows to the immutable `SLIPPAGE_BENEFICIARY`; the vault never grants ERC-20 allowances. The
/// vault can be deployed in override mode (constructor flag) so the bound Swapper can pull coverage on day one
/// without per-tx or window caps configured; operator flips override off and configures caps once risk-team has
/// set the production targets.
interface ISlippageCoverageVault {
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

    /// @notice Thrown when a `disableOverrideMode` call is made while override mode is already disabled.
    /// @custom:selector 0x005ecddb
    error AlreadyDisabled();

    /// @notice Thrown when an `enableOverrideMode` call is made while override mode is already enabled.
    /// @custom:selector 0xf2a5f75a
    error AlreadyEnabled();

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

    /// @notice Pulls `amount` of `asset` from the beneficiary back to the Slippage Coverage Vault.
    /// @dev Callable only by `SLIPPAGE_BENEFICIARY`.
    /// @param asset The asset to reimburse.
    /// @param amount The amount to reimburse.
    function reimburseCoverage(address asset, uint256 amount) external;

    /// @notice Max slippage tolerance currently in effect: `overrideMaxSlippageBps` if override mode is enabled,
    /// otherwise `maxSlippageBps`.
    function getEffectiveMaxSlippageBps() external view returns (uint16);
}
