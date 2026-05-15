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
/// @notice Holds coverage capital for rebalance-swap shortfalls. Push-based outflows to the immutable bound Swapper,
/// gated by per-tx + fixed-window caps (with lazy rollover). Override mode bypasses caps.
contract SlippageCoverageVault is AccessManaged, Multicall, ReentrancyGuardTransient, ISlippageCoverageVault {
    using SafeERC20 for IERC20;

    address internal immutable SLIPPAGE_BENEFICIARY;

    bool internal _overrideMode;
    uint16 internal _maxSlippageBps;
    uint16 internal _overrideMaxSlippageBps;
    mapping(address asset => uint256) internal _pullCapPerTx;
    mapping(address asset => Window) internal _windowByAsset;

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
    /// @dev Does not decrement consumption because it is the responsibility of the beneficiary to not pull more than
    /// necessary.
    function returnCoverage(address asset, uint256 amount) external override nonReentrant {
        require(msg.sender == SLIPPAGE_BENEFICIARY, OnlyBeneficiary());
        _pullCoverage(asset, amount);
    }

    //////////////////////////////// RESTRICTED FUNCTIONS ////////////////////////////////

    /// @inheritdoc ISlippageCoverageVault
    function enableOverrideMode() external override restricted {
        require(!_overrideMode, AlreadyEnabled());
        _overrideMode = true;
        emit OverrideModeSet(true);
    }

    /// @inheritdoc ISlippageCoverageVault
    function disableOverrideMode() external override restricted {
        require(_overrideMode, AlreadyDisabled());
        _overrideMode = false;
        emit OverrideModeSet(false);
    }

    /// @inheritdoc ISlippageCoverageVault
    function raisePullCapPerTx(address asset, uint256 newCap) external override restricted {
        uint256 oldCap = _pullCapPerTx[asset];
        require(newCap > oldCap, Errors.InvalidParameter());
        _pullCapPerTx[asset] = newCap;
        emit PullCapPerTxRaised(asset, oldCap, newCap);
    }

    /// @inheritdoc ISlippageCoverageVault
    function lowerPullCapPerTx(address asset, uint256 newCap) external override restricted {
        uint256 oldCap = _pullCapPerTx[asset];
        require(newCap < oldCap, Errors.InvalidParameter());
        _pullCapPerTx[asset] = newCap;
        emit PullCapPerTxLowered(asset, oldCap, newCap);
    }

    /// @inheritdoc ISlippageCoverageVault
    function raiseWindowCap(address asset, uint256 newCap) external override restricted {
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

    /// @inheritdoc ISlippageCoverageVault
    function lowerWindowCap(address asset, uint256 newCap) external override restricted {
        Window memory window = _windowByAsset[asset];
        uint256 oldCap = window.cap;
        require(newCap < oldCap, Errors.InvalidParameter());
        // Cast safe: bounded above by `newCap < oldCap` and `oldCap` (a `uint128`) fits in `uint128`.
        // forge-lint: disable-next-line(unsafe-typecast)
        window.cap = uint128(newCap);
        _windowByAsset[asset] = window;
        emit WindowCapLowered(asset, oldCap, newCap);
    }

    /// @inheritdoc ISlippageCoverageVault
    function raiseWindowSeconds(address asset, uint64 newWindowSeconds) external override restricted {
        Window memory window = _windowByAsset[asset];
        uint64 oldWindowSeconds = window.windowSeconds;
        require(newWindowSeconds > oldWindowSeconds, Errors.InvalidParameter());
        window.windowSeconds = newWindowSeconds;
        _windowByAsset[asset] = window;
        emit WindowSecondsRaised(asset, oldWindowSeconds, newWindowSeconds);
    }

    /// @inheritdoc ISlippageCoverageVault
    function lowerWindowSeconds(address asset, uint64 newWindowSeconds) external override restricted {
        require(newWindowSeconds > 0, Errors.InvalidParameter());
        Window memory window = _windowByAsset[asset];
        uint64 oldWindowSeconds = window.windowSeconds;
        require(newWindowSeconds < oldWindowSeconds, Errors.InvalidParameter());
        window.windowSeconds = newWindowSeconds;
        _windowByAsset[asset] = window;
        emit WindowSecondsLowered(asset, oldWindowSeconds, newWindowSeconds);
    }

    /// @inheritdoc ISlippageCoverageVault
    function setMaxSlippageBps(uint16 newBps) external override restricted {
        require(newBps <= Constants.MAX_BPS, Errors.InvalidParameter());
        uint16 oldBps = _maxSlippageBps;
        _maxSlippageBps = newBps;
        emit MaxSlippageBpsSet(oldBps, newBps);
    }

    /// @inheritdoc ISlippageCoverageVault
    function setOverrideMaxSlippageBps(uint16 newBps) external override restricted {
        require(newBps <= Constants.MAX_BPS, Errors.InvalidParameter());
        uint16 oldBps = _overrideMaxSlippageBps;
        _overrideMaxSlippageBps = newBps;
        emit OverrideMaxSlippageBpsSet(oldBps, newBps);
    }

    /// @inheritdoc ISlippageCoverageVault
    function fundCoverage(address asset, uint256 amount) external override restricted nonReentrant {
        _pullCoverage(asset, amount);
    }

    /// @inheritdoc ISlippageCoverageVault
    function sweep(address asset, uint256 amount, address to) external override restricted nonReentrant {
        require(to != address(0), Errors.ZeroAddress());
        require(amount > 0, Errors.ZeroAmount());
        IERC20(asset).safeTransfer(to, amount);
        emit Swept(asset, to, amount);
    }

    //////////////////////////////// VIEW FUNCTIONS ////////////////////////////////

    /// @inheritdoc ISlippageCoverageVault
    function getBeneficiary() external view override returns (address) {
        return SLIPPAGE_BENEFICIARY;
    }

    /// @inheritdoc ISlippageCoverageVault
    function getOverrideMode() external view override returns (bool) {
        return _overrideMode;
    }

    /// @inheritdoc ISlippageCoverageVault
    function getPullCapPerTx(address asset) external view override returns (uint256) {
        return _pullCapPerTx[asset];
    }

    /// @inheritdoc ISlippageCoverageVault
    function getWindow(address asset) external view override returns (Window memory) {
        return _windowByAsset[asset];
    }

    /// @inheritdoc ISlippageCoverageVault
    function getMaxSlippageBps() external view override returns (uint16) {
        return _maxSlippageBps;
    }

    /// @inheritdoc ISlippageCoverageVault
    function getOverrideMaxSlippageBps() external view override returns (uint16) {
        return _overrideMaxSlippageBps;
    }

    /// @inheritdoc ISlippageCoverageVault
    function getEffectiveMaxSlippageBps() external view override returns (uint16) {
        return _overrideMode ? _overrideMaxSlippageBps : _maxSlippageBps;
    }

    //////////////////////////////// INTERNAL FUNCTIONS ////////////////////////////////

    /// @dev Updates the fixed-window cap state for `asset` (with lazy rollover). Resets when the elapsed time exceeds
    /// `windowSeconds`.
    /// Reverts if the window is unconfigured (`cap == 0` or `windowSeconds == 0`) or if `consumed + amount` exceeds
    /// `cap`.
    function _consumeWindow(address asset, uint256 amount) internal {
        Window memory window = _windowByAsset[asset];
        require(window.cap > 0 && window.windowSeconds > 0, ExceedsWindowCap());
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

    function _pullCoverage(address asset, uint256 amount) internal {
        require(amount > 0, Errors.ZeroAmount());
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit CoverageFunded(asset, msg.sender, amount);
    }
}
