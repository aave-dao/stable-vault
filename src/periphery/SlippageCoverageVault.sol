// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ISlippageCoverageVault} from "src/interfaces/ISlippageCoverageVault.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title SlippageCoverageVault
/// @author Aave Labs
/// @notice Holds coverage capital for rebalance-swap shortfalls. Push-based flows to/from the immutable bound
/// Swapper: outflows cover shortfalls (gated by per-tx + fixed-window caps with lazy rollover; override mode
/// bypasses caps), inflows return unconsumed `assetIn` residual (no caps — window state tracks outflows only).
/// @dev This vault is an operational helper, not a strict on-chain bound. The bound Swapper drives the coverage
/// flow and decides whether to return leftover `assetIn`, so the caps here limit but do not guarantee the
/// Swapper's 1:1 invariant. Size the caps as an operational safety net rather than a hard protocol guarantee.
contract SlippageCoverageVault is AccessManaged, Multicall, ReentrancyGuardTransient, ISlippageCoverageVault {
    using SafeERC20 for IERC20;

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

    address internal immutable SLIPPAGE_BENEFICIARY;

    bool internal _overrideMode;
    uint16 internal _maxSlippageBps;
    uint16 internal _overrideMaxSlippageBps;
    mapping(address asset => uint256) internal _pullCapPerTx;
    mapping(address asset => Window) internal _windowByAsset;

    /// @notice Emitted when the vault is funded.
    event CoverageFunded(address indexed asset, address indexed from, uint256 amount);

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

    /// @dev Constructor.
    /// @param slippageBeneficiary The bound puller (the Swapper).
    /// @param authority The AccessManager authority for restricted setters.
    /// @param initialMaxSlippageBps Initial normal-mode max slippage tolerance in basis points.
    /// @param initialOverrideMaxSlippageBps Initial override-mode max slippage tolerance in basis points.
    /// @param initialOverrideMode Initial override-mode state. Setting `true` lets the vault accept pulls without
    /// per-tx or window cap configuration, so the system can launch with the bound Swapper functional from block one
    /// while caps are tuned later via setters.
    constructor(
        address slippageBeneficiary,
        address authority,
        uint16 initialMaxSlippageBps,
        uint16 initialOverrideMaxSlippageBps,
        bool initialOverrideMode
    ) AccessManaged(authority) {
        require(slippageBeneficiary != address(0), Errors.ZeroAddress());
        require(initialMaxSlippageBps <= Constants.MAX_BPS, Errors.InvalidParameter());
        require(initialOverrideMaxSlippageBps <= Constants.MAX_BPS, Errors.InvalidParameter());
        SLIPPAGE_BENEFICIARY = slippageBeneficiary;
        _maxSlippageBps = initialMaxSlippageBps;
        _overrideMaxSlippageBps = initialOverrideMaxSlippageBps;
        _overrideMode = initialOverrideMode;
        emit MaxSlippageBpsSet(0, initialMaxSlippageBps);
        emit OverrideMaxSlippageBpsSet(0, initialOverrideMaxSlippageBps);
        emit OverrideModeSet(initialOverrideMode);
    }

    /// @inheritdoc ISlippageCoverageVault
    function pullCoverage(address asset, uint256 amount) external override nonReentrant {
        require(msg.sender == SLIPPAGE_BENEFICIARY, OnlyBeneficiary());
        require(amount > 0, Errors.ZeroAmount());

        bool inOverride = _overrideMode;

        if (!inOverride) {
            require(amount <= _pullCapPerTx[asset], ExceedsPerTxCap());
            _consumeWindow(asset, amount);
        }

        IERC20(asset).safeTransfer(SLIPPAGE_BENEFICIARY, amount);
        emit CoveragePulled(asset, amount, inOverride);
    }

    /// @inheritdoc ISlippageCoverageVault
    /// @dev Does not decrement consumption; it is the responsibility of the beneficiary to pull what is necessary.
    function reimburseCoverage(address asset, uint256 amount) external override nonReentrant {
        require(msg.sender == SLIPPAGE_BENEFICIARY, OnlyBeneficiary());
        _takeForCoverage(asset, amount);
    }

    //////////////////////////////// RESTRICTED FUNCTIONS ////////////////////////////////

    /// @notice Enables override mode. While enabled, `pullCoverage` bypasses both per-tx and window caps and the
    /// Swapper accepts the higher `overrideMaxSlippageBps`. Reverts with `AlreadyEnabled` if already enabled.
    function enableOverrideMode() external restricted {
        require(!_overrideMode, AlreadyEnabled());
        _overrideMode = true;
        emit OverrideModeSet(true);
    }

    /// @notice Disables override mode and restores per-tx + window cap enforcement and `maxSlippageBps`. Reverts with
    /// `AlreadyDisabled` if already disabled.
    function disableOverrideMode() external restricted {
        require(_overrideMode, AlreadyDisabled());
        _overrideMode = false;
        emit OverrideModeSet(false);
    }

    /// @notice Raises the per-tx cap for an asset. Reverts if `newCap <= current`.
    function raisePullCapPerTx(address asset, uint256 newCap) external restricted {
        uint256 oldCap = _pullCapPerTx[asset];
        require(newCap > oldCap, Errors.InvalidParameter());
        _pullCapPerTx[asset] = newCap;
        emit PullCapPerTxRaised(asset, oldCap, newCap);
    }

    /// @notice Lowers the per-tx cap for an asset. Reverts if `newCap >= current`.
    function lowerPullCapPerTx(address asset, uint256 newCap) external restricted {
        uint256 oldCap = _pullCapPerTx[asset];
        require(newCap < oldCap, Errors.InvalidParameter());
        _pullCapPerTx[asset] = newCap;
        emit PullCapPerTxLowered(asset, oldCap, newCap);
    }

    /// @notice Raises the window cap for an asset. Reverts if `newCap <= current`. Preserves `windowSeconds`.
    /// @dev Boundary burst: under a fixed-window with lazy rollover, a caller can drain `newCap` at
    /// `t = windowStart + windowSeconds - 1` and another full `newCap` at `t = windowStart + windowSeconds`, for
    /// `2 * newCap` across a ~1-second span. Size `newCap` such that `2 * newCap` is an acceptable dollar exposure
    /// within `windowSeconds`.
    function raiseWindowCap(address asset, uint256 newCap) external restricted {
        require(newCap <= type(uint128).max, Errors.InvalidParameter());
        Window memory window = _windowByAsset[asset];
        uint256 oldCap = window.cap;
        require(newCap > oldCap, Errors.InvalidParameter());
        // Cast safe: bounded above by `newCap <= type(uint128).max`.
        // forge-lint: disable-next-line(unsafe-typecast)
        window.cap = uint128(newCap);
        _windowByAsset[asset] = window;
        emit WindowCapRaised(asset, oldCap, newCap);
    }

    /// @notice Lowers the window cap for an asset. Reverts if `newCap >= current`. Preserves `windowSeconds`.
    function lowerWindowCap(address asset, uint256 newCap) external restricted {
        Window memory window = _windowByAsset[asset];
        uint256 oldCap = window.cap;
        require(newCap < oldCap, Errors.InvalidParameter());
        // Cast safe: bounded above by `newCap < oldCap` and `oldCap` (a `uint128`) fits in `uint128`.
        // forge-lint: disable-next-line(unsafe-typecast)
        window.cap = uint128(newCap);
        _windowByAsset[asset] = window;
        emit WindowCapLowered(asset, oldCap, newCap);
    }

    /// @notice Raises the window length (in seconds) for an asset, lengthening the window.
    /// @dev Counter-intuitive risk direction: raising `windowSeconds` SLOWS the drain rate (same cap, more time)
    /// and is therefore a **tightening** action, gated on the operational/no-delay path. Reverts if
    /// `newWindowSeconds <= current`. Preserves `cap`. Boundary burst is `2 * cap` per `windowSeconds`; see
    /// `raiseWindowCap`.
    function raiseWindowSeconds(address asset, uint64 newWindowSeconds) external restricted {
        Window memory window = _windowByAsset[asset];
        uint64 oldWindowSeconds = window.windowSeconds;
        require(newWindowSeconds > oldWindowSeconds, Errors.InvalidParameter());
        window.windowSeconds = newWindowSeconds;
        _windowByAsset[asset] = window;
        emit WindowSecondsRaised(asset, oldWindowSeconds, newWindowSeconds);
    }

    /// @notice Lowers the window length (in seconds) for an asset, shortening the window.
    /// @dev Counter-intuitive risk direction: lowering `windowSeconds` SPEEDS UP the drain rate (same cap, less
    /// time) and is therefore a **loosening** action, gated on the admin/high-delay path. Reverts if
    /// `newWindowSeconds >= current`. Preserves `cap`.
    function lowerWindowSeconds(address asset, uint64 newWindowSeconds) external restricted {
        require(newWindowSeconds > 0, Errors.InvalidParameter());
        Window memory window = _windowByAsset[asset];
        uint64 oldWindowSeconds = window.windowSeconds;
        require(newWindowSeconds < oldWindowSeconds, Errors.InvalidParameter());
        window.windowSeconds = newWindowSeconds;
        _windowByAsset[asset] = window;
        emit WindowSecondsLowered(asset, oldWindowSeconds, newWindowSeconds);
    }

    /// @notice Sets the normal-mode max slippage tolerance in basis points.
    function setMaxSlippageBps(uint16 newBps) external restricted {
        require(newBps <= Constants.MAX_BPS, Errors.InvalidParameter());
        uint16 oldBps = _maxSlippageBps;
        _maxSlippageBps = newBps;
        emit MaxSlippageBpsSet(oldBps, newBps);
    }

    /// @notice Sets the override-mode max slippage tolerance in basis points.
    function setOverrideMaxSlippageBps(uint16 newBps) external restricted {
        require(newBps <= Constants.MAX_BPS, Errors.InvalidParameter());
        uint16 oldBps = _overrideMaxSlippageBps;
        _overrideMaxSlippageBps = newBps;
        emit OverrideMaxSlippageBpsSet(oldBps, newBps);
    }

    /// @notice Funds the vault with `amount` of `asset`. Pulls from the caller via `safeTransferFrom`.
    function fundCoverage(address asset, uint256 amount) external restricted nonReentrant {
        _takeForCoverage(asset, amount);
    }

    /// @notice Sweeps `amount` of `asset` from the vault to `to`.
    function sweep(address asset, uint256 amount, address to) external restricted nonReentrant {
        require(to != address(0), Errors.ZeroAddress());
        require(amount > 0, Errors.ZeroAmount());
        IERC20(asset).safeTransfer(to, amount);
        emit Swept(asset, to, amount);
    }

    //////////////////////////////// VIEW FUNCTIONS ////////////////////////////////

    /// @notice Getter for the immutable bound beneficiary (the Swapper).
    function getBeneficiary() external view returns (address) {
        return SLIPPAGE_BENEFICIARY;
    }

    /// @notice Getter for whether override mode is enabled.
    function getOverrideMode() external view returns (bool) {
        return _overrideMode;
    }

    /// @notice Getter for the per-tx cap for an asset.
    function getPullCapPerTx(address asset) external view returns (uint256) {
        return _pullCapPerTx[asset];
    }

    /// @notice Getter for the window state for an asset.
    function getWindow(address asset) external view returns (Window memory) {
        return _windowByAsset[asset];
    }

    /// @notice Getter for the normal-mode max slippage tolerance.
    function getMaxSlippageBps() external view returns (uint16) {
        return _maxSlippageBps;
    }

    /// @notice Getter for the override-mode max slippage tolerance.
    function getOverrideMaxSlippageBps() external view returns (uint16) {
        return _overrideMaxSlippageBps;
    }

    /// @inheritdoc ISlippageCoverageVault
    function getEffectiveMaxSlippageBps() external view override returns (uint16) {
        return _overrideMode ? _overrideMaxSlippageBps : _maxSlippageBps;
    }

    //////////////////////////////// INTERNAL FUNCTIONS ////////////////////////////////

    /// @dev Updates the fixed-window cap state for `asset` (with lazy rollover). Resets when the elapsed time exceeds
    /// `windowSeconds`.
    /// Reverts with `WindowNotConfigured` if the window is unconfigured (`cap == 0` or `windowSeconds == 0`), or with
    /// `ExceedsWindowCap` if `consumed + amount` exceeds `cap`.
    function _consumeWindow(address asset, uint256 amount) internal {
        Window memory window = _windowByAsset[asset];
        require(window.cap > 0 && window.windowSeconds > 0, WindowNotConfigured());
        if (block.timestamp >= uint256(window.windowStart) + uint256(window.windowSeconds)) {
            window.windowStart = uint64(block.timestamp);
            window.consumed = 0;
        }
        uint256 newConsumed = uint256(window.consumed) + amount;
        require(newConsumed <= uint256(window.cap), ExceedsWindowCap());
        // Cast safe: bounded above by `newConsumed <= window.cap` and `window.cap` (a `uint128`) fits in `uint128`.
        // forge-lint: disable-next-line(unsafe-typecast)
        window.consumed = uint128(newConsumed);
        _windowByAsset[asset] = window;
    }

    function _takeForCoverage(address asset, uint256 amount) internal {
        require(amount > 0, Errors.ZeroAmount());
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit CoverageFunded(asset, msg.sender, amount);
    }
}
