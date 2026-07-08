// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ISlippageCoverageVault} from "src/interfaces/ISlippageCoverageVault.sol";
import {SlippageCoverageVault} from "src/periphery/SlippageCoverageVault.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {MockReentrantErc20} from "test/mocks/MockReentrantErc20.sol";

contract SlippageCoverageVaultTest is TestWithHelpers {
    SlippageCoverageVault internal _vault;
    MockAccessManager internal _accessManager;

    MockErc20 internal _usdc; // 6 decimals
    MockErc20 internal _gho; // 18 decimals

    address internal beneficiary = makeAddr("BENEFICIARY"); // bound Swapper
    address internal operator = makeAddr("OPERATOR"); // privileged setter caller
    address internal attacker = makeAddr("ATTACKER");
    address internal funder = makeAddr("FUNDER");
    address internal sweepTo = makeAddr("SWEEP_TO");

    uint16 internal constant DEFAULT_MAX_BPS = 100; // 1%
    uint16 internal constant DEFAULT_OVERRIDE_MAX_BPS = 5_000; // 50%
    uint64 internal constant ONE_DAY = 86_400;
    uint256 internal constant LARGE_CAP = type(uint128).max - 1;

    function setUp() public {
        // Warp to a realistic mainnet-ish timestamp so that the lazy first-call window rollover triggers naturally
        // (default Foundry `block.timestamp = 1` would be < windowSeconds and skip the rollover branch on first pull,
        // leaving `windowStart = 0` and confusing assertions).
        vm.warp(1_700_000_000);

        _accessManager = new MockAccessManager(address(this));
        _vault = new SlippageCoverageVault(
            beneficiary, address(_accessManager), DEFAULT_MAX_BPS, DEFAULT_OVERRIDE_MAX_BPS, false
        );

        _usdc = new MockErc20("USD Coin", "USDC", 6);
        _gho = new MockErc20("GHO", "GHO", 18);
    }

    /* ============================ Constructor ============================ */

    function test_constructor_reverts_ifBeneficiaryIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        new SlippageCoverageVault(address(0), address(_accessManager), DEFAULT_MAX_BPS, DEFAULT_OVERRIDE_MAX_BPS, false);
    }

    function test_constructor_reverts_ifMaxSlippageBpsExceedsMaxBps() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        new SlippageCoverageVault(beneficiary, address(_accessManager), 10_001, DEFAULT_OVERRIDE_MAX_BPS, false);
    }

    function test_constructor_reverts_ifOverrideMaxSlippageBpsExceedsMaxBps() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        new SlippageCoverageVault(beneficiary, address(_accessManager), DEFAULT_MAX_BPS, 10_001, false);
    }

    function test_constructor_reverts_ifAuthorityIsNotAContract() public {
        address authority = makeAddr("AUTHORITY");
        assertEq(authority.code.length, 0);
        vm.expectRevert();
        new SlippageCoverageVault(beneficiary, authority, DEFAULT_MAX_BPS, DEFAULT_OVERRIDE_MAX_BPS, false);
    }

    function test_constructor_reverts_ifAuthorityIsZero() public {
        vm.expectRevert();
        new SlippageCoverageVault(beneficiary, address(0), DEFAULT_MAX_BPS, DEFAULT_OVERRIDE_MAX_BPS, false);
    }

    function test_constructor_setsAuthority() public view {
        assertEq(_vault.authority(), address(_accessManager));
    }

    function test_constructor_setsImmutableAndState_overrideOff() public view {
        assertEq(_vault.getBeneficiary(), beneficiary);
        assertEq(_vault.getMaxSlippageBps(), DEFAULT_MAX_BPS);
        assertEq(_vault.getOverrideMaxSlippageBps(), DEFAULT_OVERRIDE_MAX_BPS);
        assertEq(_vault.getOverrideMode(), false);
    }

    function test_constructor_setsImmutableAndState_overrideOn() public {
        SlippageCoverageVault vaultWithOverride = new SlippageCoverageVault(
            beneficiary, address(_accessManager), DEFAULT_MAX_BPS, DEFAULT_OVERRIDE_MAX_BPS, true
        );
        assertEq(vaultWithOverride.getOverrideMode(), true, "Vault should launch in override mode");
        assertEq(
            vaultWithOverride.getEffectiveMaxSlippageBps(),
            DEFAULT_OVERRIDE_MAX_BPS,
            "Effective bound should reflect override-mode bps from block one"
        );
    }

    function test_constructor_emitsInitialBoundsEvents_overrideOff() public {
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.MaxSlippageBpsSet(0, DEFAULT_MAX_BPS);
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.OverrideMaxSlippageBpsSet(0, DEFAULT_OVERRIDE_MAX_BPS);
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.OverrideModeSet(false);
        new SlippageCoverageVault(
            beneficiary, address(_accessManager), DEFAULT_MAX_BPS, DEFAULT_OVERRIDE_MAX_BPS, false
        );
    }

    function test_constructor_emitsInitialBoundsEvents_overrideOn() public {
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.MaxSlippageBpsSet(0, DEFAULT_MAX_BPS);
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.OverrideMaxSlippageBpsSet(0, DEFAULT_OVERRIDE_MAX_BPS);
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.OverrideModeSet(true);
        new SlippageCoverageVault(beneficiary, address(_accessManager), DEFAULT_MAX_BPS, DEFAULT_OVERRIDE_MAX_BPS, true);
    }

    /* ============================ pullCoverage — gates ============================ */

    /// @dev Path B: only the immutable bound beneficiary can ever pull.
    function test_pullCoverage_reverts_ifCallerIsNotBeneficiary() public {
        _configureUsdcCaps(LARGE_CAP, LARGE_CAP, ONE_DAY);
        _fund(_usdc, 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.OnlyBeneficiary.selector));
        vm.prank(attacker);
        _vault.pullCoverage(address(_usdc), 1);
    }

    function test_pullCoverage_reverts_ifAmountIsZero() public {
        _configureUsdcCaps(LARGE_CAP, LARGE_CAP, ONE_DAY);
        _fund(_usdc, 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 0);
    }

    function test_pullCoverage_reverts_ifAssetUnconfiguredAndNotInOverride() public {
        _fund(_usdc, 1_000e6);

        // pullCapPerTx == 0 → first guard trips.
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsPerTxCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);
    }

    function test_pullCoverage_reverts_ifAmountExceedsPerTxCap() public {
        _configureUsdcCaps(5_000e6, 50_000e6, ONE_DAY);
        _fund(_usdc, 50_000e6);

        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsPerTxCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 5_000e6 + 1);
    }

    function test_pullCoverage_reverts_ifWindowUnconfigured() public {
        // Per-tx is set but window is not (cap=0, windowSeconds=0).
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 5_000e6);
        _fund(_usdc, 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.WindowNotConfigured.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1_000);
    }

    function test_pullCoverage_reverts_ifVaultUnderfunded() public {
        _configureUsdcCaps(5_000e6, 50_000e6, ONE_DAY);
        // No funding.

        vm.expectRevert(); // SafeERC20FailedOperation propagates from the underlying ERC20
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1_000e6);
    }

    /* ============================ pullCoverage — happy path ============================ */

    function test_pullCoverage_transfersToBeneficiaryAndUpdatesWindow() public {
        _configureUsdcCaps(5_000e6, 50_000e6, ONE_DAY);
        _fund(_usdc, 50_000e6);

        uint256 amount = 4_999e6;

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), amount);

        assertEq(_usdc.balanceOf(beneficiary), amount);
        assertEq(_usdc.balanceOf(address(_vault)), 50_000e6 - amount);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.consumed, amount);
        assertEq(w.cap, 50_000e6);
        assertEq(w.windowSeconds, ONE_DAY);
        assertEq(w.windowStart, block.timestamp);
    }

    function test_pullCoverage_emitsCoveragePulledWithOverrideFalseInNormalMode() public {
        _configureUsdcCaps(5_000e6, 50_000e6, ONE_DAY);
        _fund(_usdc, 50_000e6);

        vm.expectEmit(true, false, false, true);
        emit ISlippageCoverageVault.CoveragePulled(address(_usdc), 1_000e6, false);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1_000e6);
    }

    function test_pullCoverage_emitsCoveragePulledWithOverrideTrueInOverrideMode() public {
        vm.prank(operator);
        _vault.enableOverrideMode();
        _fund(_usdc, 1_000e6);

        vm.expectEmit(true, false, false, true);
        emit ISlippageCoverageVault.CoveragePulled(address(_usdc), 100e6, true);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 100e6);
    }

    function test_pullCoverage_assetsAreThrottledIndependently() public {
        // Drain USDC's window, GHO must still be available.
        _configureUsdcCaps(50_000e6, 50_000e6, ONE_DAY);
        _configureGhoCaps(50_000e18, 50_000e18, ONE_DAY);
        _fund(_usdc, 50_000e6);
        _fund(_gho, 50_000e18);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000e6);

        // USDC window full → reverts.
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        _vault.pullCoverage(address(_usdc), 1);

        // GHO window untouched → succeeds.
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_gho), 50_000e18);
        assertEq(_gho.balanceOf(beneficiary), 50_000e18);
    }

    /* ============================ Window mechanics ============================ */

    function test_pullCoverage_firstCallSetsWindowStart() public {
        _configureUsdcCaps(5_000e6, 50_000e6, ONE_DAY);
        _fund(_usdc, 50_000e6);

        // Window state defaults are all zero. After first pull, windowStart = block.timestamp.
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1_000e6);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.windowStart, block.timestamp);
        assertEq(w.consumed, 1_000e6);
    }

    function test_pullCoverage_rollsOverAtBoundary() public {
        _configureUsdcCaps(50_000e6, 50_000e6, ONE_DAY);
        _fund(_usdc, 200_000e6);

        // Drain the entire window.
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000e6);
        uint256 firstWindowStart = block.timestamp;

        // Just before rollover → reverts.
        vm.warp(firstWindowStart + ONE_DAY - 1);
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);

        // At the boundary → rolls over and succeeds.
        vm.warp(firstWindowStart + ONE_DAY);
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000e6);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.windowStart, firstWindowStart + ONE_DAY);
        assertEq(w.consumed, 50_000e6);
    }

    /// @dev Documented design choice: a fixed-window counter allows up to 2x cap drained across the boundary.
    /// Treasury sizes the cap so 2x is acceptable maximum exposure within ~1 second.
    function test_pullCoverage_boundaryBurstAllows2xCapInOneSecond() public {
        _configureUsdcCaps(50_000e6, 50_000e6, ONE_DAY);
        _fund(_usdc, 200_000e6);

        uint256 t0 = block.timestamp;

        // Anchor windowStart to t0 with a 1-wei pull (the cap minus 1 below absorbs this).
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);

        // Drain the rest of the window at t = t0 + windowSeconds - 1.
        vm.warp(t0 + ONE_DAY - 1);
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000e6 - 1);

        // At rollover boundary, drain another full cap — 2x cap minus 1 in ~1 second.
        vm.warp(t0 + ONE_DAY);
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000e6);

        // Total drained ~ 2 × cap.
        assertEq(_usdc.balanceOf(beneficiary), 100_000e6);
    }

    function test_pullCoverage_rollsOverAfterMultiDayIdle() public {
        _configureUsdcCaps(50_000e6, 50_000e6, ONE_DAY);
        _fund(_usdc, 100_000e6);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000e6);

        // Idle for 30 days, then pull — should roll over once and accept the full cap again.
        vm.warp(block.timestamp + 30 days);
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000e6);

        assertEq(_usdc.balanceOf(beneficiary), 100_000e6);
    }

    function test_pullCoverage_manySmallPullsTotalingCap_revertsOnNext() public {
        _configureUsdcCaps(1_000e6, 10_000e6, ONE_DAY);
        _fund(_usdc, 100_000e6);

        // 10 × 1_000 = 10_000 (the cap).
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(beneficiary);
            _vault.pullCoverage(address(_usdc), 1_000e6);
        }

        // 11th pull of any amount must revert.
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.consumed, 10_000e6);
    }

    function test_pullCoverage_oneSecondWindow_rollsOverEverySecond() public {
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 1_000e6);
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), 1_000e6);
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), 1);
        _fund(_usdc, 100_000e6);

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(beneficiary);
            _vault.pullCoverage(address(_usdc), 1_000e6);
        }

        assertEq(_usdc.balanceOf(beneficiary), 10_000e6);
    }

    function test_pullCoverage_largeWindowSeconds_pullsTrickleOver() public {
        // windowSeconds = uint64.max → effectively a one-shot global cap.
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), LARGE_CAP);
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), 10_000e6);
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), type(uint64).max);
        _fund(_usdc, 100_000e6);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 10_000e6);

        // Many years later, still no rollover (windowSeconds = uint64.max ≈ 5.8e11 years).
        vm.warp(block.timestamp + 365 days * 100);
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);
    }

    /// @dev Cap raise mid-window should grant headroom immediately without resetting consumed.
    function test_pullCoverage_capRaisedMidWindow_grantsHeadroomImmediately() public {
        // Per-tx must accommodate the largest planned pull (10k).
        _configureUsdcCaps(10_000e6, 10_000e6, ONE_DAY);
        _fund(_usdc, 100_000e6);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 10_000e6);

        // Window is full at 10k.
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);

        // Raise window cap to 20k mid-window.
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), 20_000e6);

        // Now an additional 10k is allowed (consumed not reset).
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 10_000e6);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.consumed, 20_000e6);
    }

    /// @dev Cap lower below current consumed: subsequent pulls revert until rollover.
    function test_pullCoverage_capLoweredBelowConsumed_blocksPullsUntilRollover() public {
        _configureUsdcCaps(5_000e6, 10_000e6, ONE_DAY);
        _fund(_usdc, 50_000e6);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 5_000e6);
        SlippageCoverageVault.Window memory wBefore = _vault.getWindow(address(_usdc));
        assertEq(wBefore.consumed, 5_000e6);

        // Lower window cap to 1k. consumed=5k > new cap=1k.
        vm.prank(operator);
        _vault.lowerWindowCap(address(_usdc), 1_000e6);

        // Any pull reverts: consumed (5k) + amount > cap (1k).
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);

        // After rollover, full new cap available (per-tx cap is already 5k ≥ 1k, no adjustment needed).
        vm.warp(block.timestamp + ONE_DAY);
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1_000e6);
        assertEq(_vault.getWindow(address(_usdc)).consumed, 1_000e6);
    }

    /// @dev windowSeconds shrunk mid-window via lowerWindowSeconds: the new windowSeconds applies on next rollover
    /// check.
    function test_pullCoverage_windowSecondsShrunkMidWindow_rollsOverSooner() public {
        _configureUsdcCaps(50_000e6, 10_000e6, ONE_DAY);
        _fund(_usdc, 100_000e6);

        uint256 t0 = block.timestamp;
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 10_000e6);

        // Half a day in, lower window to 1k cap and shorten window to 1 hour.
        vm.warp(t0 + ONE_DAY / 2);
        vm.prank(operator);
        _vault.lowerWindowCap(address(_usdc), 1_000e6);
        vm.prank(operator);
        _vault.lowerWindowSeconds(address(_usdc), 1 hours);

        // 1h after t0 has already passed → next pull rolls over (windowStart + 1h ≤ now).
        vm.prank(operator);
        _vault.lowerPullCapPerTx(address(_usdc), 1_000e6);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 500e6);
        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.consumed, 500e6);
        assertEq(w.windowStart, block.timestamp);
    }

    function testFuzz_pullCoverage_consumedTracksSumOfPulls(uint8 numPulls, uint96 amountSeed) public {
        numPulls = uint8(bound(numPulls, 1, 50));
        uint256 baseAmount = uint256(amountSeed) % 1_000e6 + 1;

        _configureUsdcCaps(LARGE_CAP, LARGE_CAP, ONE_DAY);
        _fund(_usdc, type(uint128).max);

        uint256 totalPulled;
        for (uint256 i = 0; i < numPulls; i++) {
            uint256 amount = baseAmount + i;
            vm.prank(beneficiary);
            _vault.pullCoverage(address(_usdc), amount);
            totalPulled += amount;
        }

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.consumed, totalPulled);
    }

    /* ============================ Override mode ============================ */

    function test_enableOverrideMode_revertsIfUnauthorized() public {
        _accessManager.mockRejectCall(attacker, address(_vault), SlippageCoverageVault.enableOverrideMode.selector);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        vm.prank(attacker);
        _vault.enableOverrideMode();
    }

    function test_disableOverrideMode_revertsIfUnauthorized() public {
        vm.prank(operator);
        _vault.enableOverrideMode();
        _accessManager.mockRejectCall(attacker, address(_vault), SlippageCoverageVault.disableOverrideMode.selector);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        vm.prank(attacker);
        _vault.disableOverrideMode();
    }

    function test_enableOverrideMode_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.OverrideModeSet(true);
        vm.prank(operator);
        _vault.enableOverrideMode();
    }

    function test_disableOverrideMode_emitsEvent() public {
        vm.prank(operator);
        _vault.enableOverrideMode();
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.OverrideModeSet(false);
        vm.prank(operator);
        _vault.disableOverrideMode();
    }

    function test_enableOverrideMode_revertsIfAlreadyEnabled() public {
        vm.prank(operator);
        _vault.enableOverrideMode();
        vm.expectRevert(abi.encodeWithSelector(SlippageCoverageVault.AlreadyEnabled.selector));
        vm.prank(operator);
        _vault.enableOverrideMode();
    }

    function test_disableOverrideMode_revertsIfAlreadyDisabled() public {
        vm.expectRevert(abi.encodeWithSelector(SlippageCoverageVault.AlreadyDisabled.selector));
        vm.prank(operator);
        _vault.disableOverrideMode();
    }

    function test_pullCoverage_overrideModeBypassesPerTxCap() public {
        // Per-tx cap = 100, request 1_000_000 in override mode → succeeds.
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 100);
        vm.prank(operator);
        _vault.enableOverrideMode();
        _fund(_usdc, 1_000_000);

        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1_000_000);
        assertEq(_usdc.balanceOf(beneficiary), 1_000_000);
    }

    function test_pullCoverage_overrideModeBypassesWindowCap() public {
        _configureUsdcCaps(5_000e6, 5_000e6, ONE_DAY);
        _fund(_usdc, 1_000_000e6);

        // Drain the normal-mode window.
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 5_000e6);

        // Flip override; pull amounts that would otherwise revert.
        vm.prank(operator);
        _vault.enableOverrideMode();
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 100_000e6);

        assertEq(_usdc.balanceOf(beneficiary), 105_000e6);
    }

    /// @dev Crucial: override mode must NOT bump `consumed`. Otherwise turning override off would leave a poisoned
    /// counter that bricks normal-mode operation.
    function test_pullCoverage_overrideModeDoesNotPoisonWindowState() public {
        _configureUsdcCaps(5_000e6, 5_000e6, ONE_DAY);
        _fund(_usdc, 100_000e6);

        // Override on, drain a lot.
        vm.prank(operator);
        _vault.enableOverrideMode();
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 100_000e6);

        SlippageCoverageVault.Window memory wDuringOverride = _vault.getWindow(address(_usdc));
        assertEq(wDuringOverride.consumed, 0); // never touched
        assertEq(wDuringOverride.windowStart, 0); // first call was in override → window untouched

        // Top up, flip override off, pull within normal cap → still works fully.
        _fund(_usdc, 5_000e6);
        vm.prank(operator);
        _vault.disableOverrideMode();
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 5_000e6);

        SlippageCoverageVault.Window memory wAfter = _vault.getWindow(address(_usdc));
        assertEq(wAfter.consumed, 5_000e6);
    }

    function test_pullCoverage_overrideFlipBetweenPulls_secondPullRespectsCaps() public {
        _configureUsdcCaps(1_000, 1_000, ONE_DAY);
        _fund(_usdc, 100_000_000);

        // Override on: pull above per-tx cap.
        vm.prank(operator);
        _vault.enableOverrideMode();
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000);

        // Flip off: any pull above per-tx cap reverts.
        vm.prank(operator);
        _vault.disableOverrideMode();
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsPerTxCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1_001);
    }

    /* ============================ Setters: pullCapPerTx ============================ */

    function test_raisePullCapPerTx_setsAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit SlippageCoverageVault.PullCapPerTxRaised(address(_usdc), 0, 5_000e6);
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 5_000e6);

        assertEq(_vault.getPullCapPerTx(address(_usdc)), 5_000e6);
    }

    function test_raisePullCapPerTx_reverts_ifNotIncreasing() public {
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 5_000e6);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 5_000e6); // equal

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 4_999e6); // smaller
    }

    function test_raisePullCapPerTx_reverts_ifUnauthorized() public {
        _accessManager.mockRejectCall(attacker, address(_vault), SlippageCoverageVault.raisePullCapPerTx.selector);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        vm.prank(attacker);
        _vault.raisePullCapPerTx(address(_usdc), 1);
    }

    function test_lowerPullCapPerTx_setsAndEmits() public {
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 5_000e6);

        vm.expectEmit(true, false, false, true);
        emit SlippageCoverageVault.PullCapPerTxLowered(address(_usdc), 5_000e6, 1_000e6);
        vm.prank(operator);
        _vault.lowerPullCapPerTx(address(_usdc), 1_000e6);

        assertEq(_vault.getPullCapPerTx(address(_usdc)), 1_000e6);
    }

    function test_lowerPullCapPerTx_canSetToZero() public {
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 5_000e6);

        vm.prank(operator);
        _vault.lowerPullCapPerTx(address(_usdc), 0);

        assertEq(_vault.getPullCapPerTx(address(_usdc)), 0);
    }

    function test_lowerPullCapPerTx_reverts_ifNotDecreasing() public {
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), 5_000e6);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.lowerPullCapPerTx(address(_usdc), 5_000e6); // equal

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.lowerPullCapPerTx(address(_usdc), 5_001e6); // larger
    }

    /* ============================ Setters: windowCap ============================ */

    function test_raiseWindowCap_setsAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit SlippageCoverageVault.WindowCapRaised(address(_usdc), 0, 50_000e6);
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), 50_000e6);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.cap, 50_000e6);
    }

    function test_raiseWindowCap_reverts_ifNewCapExceedsUint128Max() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), uint256(type(uint128).max) + 1);
    }

    function test_raiseWindowCap_reverts_ifNotIncreasing() public {
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), 50_000e6);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), 50_000e6);
    }

    function test_lowerWindowCap_setsAndEmits() public {
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), 50_000e6);

        vm.expectEmit(true, false, false, true);
        emit SlippageCoverageVault.WindowCapLowered(address(_usdc), 50_000e6, 10_000e6);
        vm.prank(operator);
        _vault.lowerWindowCap(address(_usdc), 10_000e6);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.cap, 10_000e6);
    }

    function test_lowerWindowCap_reverts_ifNotDecreasing() public {
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), 50_000e6);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.lowerWindowCap(address(_usdc), 50_000e6);
    }

    /* ============================ Setters: windowSeconds ============================ */

    function test_raiseWindowSeconds_setsAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit SlippageCoverageVault.WindowSecondsRaised(address(_usdc), 0, uint64(ONE_DAY));
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), uint64(ONE_DAY));

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.windowSeconds, ONE_DAY);
    }

    function test_raiseWindowSeconds_reverts_ifNotIncreasing() public {
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), uint64(ONE_DAY));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), uint64(ONE_DAY));
    }

    function test_lowerWindowSeconds_setsAndEmits() public {
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), uint64(ONE_DAY));

        vm.expectEmit(true, false, false, true);
        emit SlippageCoverageVault.WindowSecondsLowered(address(_usdc), uint64(ONE_DAY), 1 hours);
        vm.prank(operator);
        _vault.lowerWindowSeconds(address(_usdc), 1 hours);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.windowSeconds, 1 hours);
    }

    function test_lowerWindowSeconds_reverts_ifNotDecreasing() public {
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), uint64(ONE_DAY));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.lowerWindowSeconds(address(_usdc), uint64(ONE_DAY));
    }

    function test_lowerWindowSeconds_reverts_ifZero() public {
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), uint64(ONE_DAY));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.lowerWindowSeconds(address(_usdc), 0);
    }

    /* ============================ Setters: slippage bounds ============================ */

    function test_setMaxSlippageBps_setsAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.MaxSlippageBpsSet(DEFAULT_MAX_BPS, 250);
        vm.prank(operator);
        _vault.setMaxSlippageBps(250);

        assertEq(_vault.getMaxSlippageBps(), 250);
    }

    function test_setMaxSlippageBps_reverts_ifAboveMaxBps() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.setMaxSlippageBps(10_001);
    }

    function test_setMaxSlippageBps_acceptsExactly100Percent() public {
        vm.prank(operator);
        _vault.setMaxSlippageBps(uint16(Constants.MAX_BPS));
        assertEq(_vault.getMaxSlippageBps(), Constants.MAX_BPS);
    }

    function test_setOverrideMaxSlippageBps_setsAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit SlippageCoverageVault.OverrideMaxSlippageBpsSet(DEFAULT_OVERRIDE_MAX_BPS, 7_500);
        vm.prank(operator);
        _vault.setOverrideMaxSlippageBps(7_500);

        assertEq(_vault.getOverrideMaxSlippageBps(), 7_500);
    }

    function test_setOverrideMaxSlippageBps_reverts_ifAboveMaxBps() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(operator);
        _vault.setOverrideMaxSlippageBps(10_001);
    }

    /* ============================ getEffectiveMaxSlippageBps ============================ */

    function test_getEffectiveMaxSlippageBps_returnsNormalBps_whenOverrideOff() public view {
        // Sanity: override is off by default.
        assertEq(_vault.getOverrideMode(), false);
        assertEq(_vault.getEffectiveMaxSlippageBps(), DEFAULT_MAX_BPS);
    }

    function test_getEffectiveMaxSlippageBps_returnsOverrideBps_whenOverrideOn() public {
        vm.prank(operator);
        _vault.enableOverrideMode();
        assertEq(_vault.getEffectiveMaxSlippageBps(), DEFAULT_OVERRIDE_MAX_BPS);
    }

    function test_getEffectiveMaxSlippageBps_tracksLatestSetters() public {
        // Mutate normal-mode bound while override is off.
        vm.prank(operator);
        _vault.setMaxSlippageBps(123);
        assertEq(_vault.getEffectiveMaxSlippageBps(), 123);

        // Flip override on; effective bound switches to override-mode value.
        vm.prank(operator);
        _vault.enableOverrideMode();
        assertEq(_vault.getEffectiveMaxSlippageBps(), DEFAULT_OVERRIDE_MAX_BPS);

        // Mutate override-mode bound; effective bound updates.
        vm.prank(operator);
        _vault.setOverrideMaxSlippageBps(456);
        assertEq(_vault.getEffectiveMaxSlippageBps(), 456);

        // Flip override off; effective bound switches back to the (already-mutated) normal-mode value.
        vm.prank(operator);
        _vault.disableOverrideMode();
        assertEq(_vault.getEffectiveMaxSlippageBps(), 123);
    }

    /* ============================ fundCoverage ============================ */

    function test_fundCoverage_pullsFromCallerAndEmits() public {
        _usdc.mint(funder, 10_000e6);
        vm.prank(funder);
        _usdc.approve(address(_vault), 10_000e6);

        vm.expectEmit(true, true, false, true);
        emit SlippageCoverageVault.CoverageFunded(address(_usdc), funder, 10_000e6);

        vm.prank(funder);
        _vault.fundCoverage(address(_usdc), 10_000e6);

        assertEq(_usdc.balanceOf(address(_vault)), 10_000e6);
        assertEq(_usdc.balanceOf(funder), 0);
    }

    function test_fundCoverage_reverts_ifAmountZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        vm.prank(funder);
        _vault.fundCoverage(address(_usdc), 0);
    }

    function test_fundCoverage_reverts_ifUnauthorized() public {
        _accessManager.mockRejectCall(attacker, address(_vault), SlippageCoverageVault.fundCoverage.selector);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        vm.prank(attacker);
        _vault.fundCoverage(address(_usdc), 1);
    }

    function test_fundCoverage_multipleFunders_balancesAccumulate() public {
        address funderA = makeAddr("FUNDER_A");
        address funderB = makeAddr("FUNDER_B");

        _usdc.mint(funderA, 1_000e6);
        _usdc.mint(funderB, 500e6);
        vm.prank(funderA);
        _usdc.approve(address(_vault), 1_000e6);
        vm.prank(funderB);
        _usdc.approve(address(_vault), 500e6);

        vm.prank(funderA);
        _vault.fundCoverage(address(_usdc), 1_000e6);
        vm.prank(funderB);
        _vault.fundCoverage(address(_usdc), 500e6);

        assertEq(_usdc.balanceOf(address(_vault)), 1_500e6);
    }

    /* ============================ returnCoverage ============================ */

    /// @dev Beneficiary gate: the swap-refund path is only callable by the immutable bound Swapper. An attacker
    /// being able to call this would let them forge `CoverageFunded` audit events.
    function test_reimburseCoverage_reverts_ifCallerIsNotBeneficiary() public {
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.OnlyBeneficiary.selector));
        vm.prank(attacker);
        _vault.reimburseCoverage(address(_usdc), 1);
    }

    /// @dev Operator is privileged for the restricted setters; the beneficiary gate must still reject them.
    function test_reimburseCoverage_reverts_ifCallerIsOperator() public {
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.OnlyBeneficiary.selector));
        vm.prank(operator);
        _vault.reimburseCoverage(address(_usdc), 1);
    }

    /// @dev Funder can call `fundCoverage` (the governance-funding path) but is not the bound beneficiary, so the
    /// swap-refund path must reject them too.
    function test_reimburseCoverage_reverts_ifCallerIsFunder() public {
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.OnlyBeneficiary.selector));
        vm.prank(funder);
        _vault.reimburseCoverage(address(_usdc), 1);
    }

    function test_reimburseCoverage_reverts_ifAmountIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        vm.prank(beneficiary);
        _vault.reimburseCoverage(address(_usdc), 0);
    }

    function test_reimburseCoverage_pullsFromBeneficiaryAndEmits() public {
        _usdc.mint(beneficiary, 1_000e6);
        vm.prank(beneficiary);
        _usdc.approve(address(_vault), 1_000e6);

        vm.expectEmit(true, true, false, true);
        emit SlippageCoverageVault.CoverageFunded(address(_usdc), beneficiary, 1_000e6);

        vm.prank(beneficiary);
        _vault.reimburseCoverage(address(_usdc), 1_000e6);

        assertEq(_usdc.balanceOf(address(_vault)), 1_000e6);
        assertEq(_usdc.balanceOf(beneficiary), 0);
    }

    /// @dev Returns are inflows; window-cap accounting tracks outflows only. A return must not credit back the
    /// window budget (otherwise a malicious rebalancer could pull, return, and pull again to bypass the rate limit).
    function test_reimburseCoverage_doesNotConsumeOrRestoreWindowCap() public {
        _configureUsdcCaps(5_000e6, 50_000e6, ONE_DAY);

        // Pull first to populate windowStart and consumed.
        _fund(_usdc, 50_000e6);
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 5_000e6);

        SlippageCoverageVault.Window memory wBefore = _vault.getWindow(address(_usdc));

        // Return funds; window state must be byte-identical afterwards.
        _usdc.mint(beneficiary, 5_000e6);
        vm.prank(beneficiary);
        _usdc.approve(address(_vault), 5_000e6);
        vm.prank(beneficiary);
        _vault.reimburseCoverage(address(_usdc), 5_000e6);

        SlippageCoverageVault.Window memory wAfter = _vault.getWindow(address(_usdc));
        assertEq(wAfter.windowStart, wBefore.windowStart, "windowStart shifted");
        assertEq(wAfter.windowSeconds, wBefore.windowSeconds, "windowSeconds shifted");
        assertEq(wAfter.consumed, wBefore.consumed, "consumed shifted");
        assertEq(wAfter.cap, wBefore.cap, "cap shifted");
    }

    /// @dev Inflows do not depend on override mode — the only gate is the bound-beneficiary check, so returns
    /// succeed regardless of mode.
    function test_reimburseCoverage_worksInOverrideMode() public {
        vm.prank(operator);
        _vault.enableOverrideMode();

        _usdc.mint(beneficiary, 1_000e6);
        vm.prank(beneficiary);
        _usdc.approve(address(_vault), 1_000e6);

        vm.prank(beneficiary);
        _vault.reimburseCoverage(address(_usdc), 1_000e6);

        assertEq(_usdc.balanceOf(address(_vault)), 1_000e6);
    }

    /* ============================ sweep ============================ */

    function test_sweep_transfersAndEmits() public {
        _fund(_usdc, 10_000e6);

        vm.expectEmit(true, true, false, true);
        emit SlippageCoverageVault.Swept(address(_usdc), sweepTo, 10_000e6);

        vm.prank(operator);
        _vault.sweep(address(_usdc), 10_000e6, sweepTo);

        assertEq(_usdc.balanceOf(sweepTo), 10_000e6);
        assertEq(_usdc.balanceOf(address(_vault)), 0);
    }

    function test_sweep_reverts_ifZeroAddress() public {
        _fund(_usdc, 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        vm.prank(operator);
        _vault.sweep(address(_usdc), 10_000e6, address(0));
    }

    function test_sweep_reverts_ifZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        vm.prank(operator);
        _vault.sweep(address(_usdc), 0, sweepTo);
    }

    function test_sweep_reverts_ifUnauthorized() public {
        _accessManager.mockRejectCall(attacker, address(_vault), SlippageCoverageVault.sweep.selector);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        vm.prank(attacker);
        _vault.sweep(address(_usdc), 1, sweepTo);
    }

    function test_sweep_partial_leavesRestIntact() public {
        _fund(_usdc, 10_000e6);

        vm.prank(operator);
        _vault.sweep(address(_usdc), 3_000e6, sweepTo);

        assertEq(_usdc.balanceOf(sweepTo), 3_000e6);
        assertEq(_usdc.balanceOf(address(_vault)), 7_000e6);
    }

    /// @dev After sweep drains the vault, pullCoverage reverts on the underlying transfer.
    function test_sweep_drained_pullCoverageReverts() public {
        _configureUsdcCaps(5_000e6, 50_000e6, ONE_DAY);
        _fund(_usdc, 10_000e6);

        vm.prank(operator);
        _vault.sweep(address(_usdc), 10_000e6, sweepTo);

        vm.expectRevert(); // SafeERC20FailedOperation
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1_000e6);
    }

    /* ============================ Adversarial scenarios ============================ */

    /// @dev Path A regression: the vault never grants ERC-20 approvals, so `transferFrom` from any third party fails.
    function test_adversarial_vaultNeverGrantsApprovals() public {
        _fund(_usdc, 10_000e6);
        // Allowance from vault to attacker is 0, has never been set, vault has no code path that sets it.
        assertEq(_usdc.allowance(address(_vault), attacker), 0);
        assertEq(_usdc.allowance(address(_vault), beneficiary), 0);
        assertEq(_usdc.allowance(address(_vault), operator), 0);
    }

    /// @dev If the asset has a malicious transfer hook that re-enters pullCoverage, the transient nonReentrant blocks.
    function test_adversarial_pullCoverage_reentrantTokenIsBlocked() public {
        MockReentrantErc20 hostile = new MockReentrantErc20("Hostile", "H", 18);
        _accessManager.mockAllowCall(operator, address(_vault), SlippageCoverageVault.raisePullCapPerTx.selector);
        _accessManager.mockAllowCall(operator, address(_vault), SlippageCoverageVault.raiseWindowCap.selector);
        _accessManager.mockAllowCall(operator, address(_vault), SlippageCoverageVault.raiseWindowSeconds.selector);

        vm.prank(operator);
        _vault.raisePullCapPerTx(address(hostile), LARGE_CAP);
        vm.prank(operator);
        _vault.raiseWindowCap(address(hostile), LARGE_CAP);
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(hostile), ONE_DAY);

        hostile.mint(address(_vault), 1_000e18);

        // Hostile's transfer will call back vault.pullCoverage in the same tx.
        hostile.setReentrantCall(
            address(_vault), abi.encodeCall(ISlippageCoverageVault.pullCoverage, (address(hostile), 100))
        );

        // Outer call would set the transient nonReentrant flag → inner call reverts → propagates.
        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(hostile), 100);
    }

    /// @dev Funding + reentrancy: a hostile transferFrom that calls back into pullCoverage must revert.
    function test_adversarial_fundCoverage_reentrantTokenIsBlocked() public {
        MockReentrantErc20 hostile = new MockReentrantErc20("Hostile", "H", 18);
        hostile.setReentrancyOnTransferFrom(true);

        hostile.mint(funder, 1_000e18);
        vm.prank(funder);
        hostile.approve(address(_vault), 1_000e18);

        // While funding, the token tries to re-enter pullCoverage.
        hostile.setReentrantCall(
            address(_vault), abi.encodeCall(ISlippageCoverageVault.pullCoverage, (address(hostile), 100))
        );

        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        vm.prank(funder);
        _vault.fundCoverage(address(hostile), 1_000e18);
    }

    /// @dev Returning + reentrancy: the same hostile-token shape but reached via the beneficiary-gated path.
    function test_adversarial_reimburseCoverage_reentrantTokenIsBlocked() public {
        MockReentrantErc20 hostile = new MockReentrantErc20("Hostile", "H", 18);
        hostile.setReentrancyOnTransferFrom(true);

        hostile.mint(beneficiary, 1_000e18);
        vm.prank(beneficiary);
        hostile.approve(address(_vault), 1_000e18);

        hostile.setReentrantCall(
            address(_vault), abi.encodeCall(ISlippageCoverageVault.pullCoverage, (address(hostile), 100))
        );

        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        vm.prank(beneficiary);
        _vault.reimburseCoverage(address(hostile), 1_000e18);
    }

    /// @dev Many small pulls totaling exactly cap is fine; +1 reverts.
    function test_adversarial_drainExactlyCap_revertsOnNextWei() public {
        _configureUsdcCaps(LARGE_CAP, 100, ONE_DAY); // small cap
        _fund(_usdc, 1_000);

        for (uint256 i = 0; i < 100; i++) {
            vm.prank(beneficiary);
            _vault.pullCoverage(address(_usdc), 1);
        }

        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.consumed, 100);
    }

    /// @dev Manager attempts a per-tx cap bypass via many sub-cap pulls. Window cap eventually catches them.
    function test_adversarial_manyPullsUnderPerTxCap_blockedByWindowCap() public {
        _configureUsdcCaps(1_000, 5_000, ONE_DAY);
        _fund(_usdc, 100_000);

        // 5 × 1_000 = 5_000 (= window cap).
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(beneficiary);
            _vault.pullCoverage(address(_usdc), 1_000);
        }

        // 6th pull blocked.
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);
    }

    /// @dev windowSeconds matters: shrinking the window does NOT reset windowStart, so some "wasted" idle time may
    /// accelerate rollover. Worth pinning behavior.
    function test_adversarial_windowSecondsShrunk_doesNotResetStart() public {
        _configureUsdcCaps(LARGE_CAP, 5_000e6, ONE_DAY);
        _fund(_usdc, 100_000e6);

        uint256 t0 = block.timestamp;
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 5_000e6);

        // Lower the cap and shrink windowSeconds to 1 hour.
        vm.prank(operator);
        _vault.lowerWindowCap(address(_usdc), 4_999e6);
        vm.prank(operator);
        _vault.lowerWindowSeconds(address(_usdc), 1 hours);

        // Warp 1 hour after t0 → rollover triggers (now >= t0 + 1h).
        vm.warp(t0 + 1 hours);
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 4_000e6);

        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_usdc));
        assertEq(w.windowStart, t0 + 1 hours);
        assertEq(w.consumed, 4_000e6);
    }

    /// @dev Override toggled rapidly: each pull's flag matches the value AT pull time.
    function test_adversarial_rapidOverrideFlips_eachPullEvaluatedIndependently() public {
        _configureUsdcCaps(100, 100, ONE_DAY);
        _fund(_usdc, 1_000_000);

        // Override on → pull big.
        vm.prank(operator);
        _vault.enableOverrideMode();
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000);

        // Override off → must respect cap.
        vm.prank(operator);
        _vault.disableOverrideMode();
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsPerTxCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 101);

        // Within cap.
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 100);

        // Override on again → bypass.
        vm.prank(operator);
        _vault.enableOverrideMode();
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 50_000);
    }

    /// @dev `consumed + amount` near uint128.max must still revert cleanly via the cap check (no silent wrap).
    function test_adversarial_consumedNearUint128Max_revertsOnCapCheck() public {
        // Configure cap = uint128.max - 1.
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), LARGE_CAP);
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), LARGE_CAP);
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), ONE_DAY);
        _fund(_usdc, type(uint128).max);

        // Fill the bucket.
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), LARGE_CAP);

        // One more wei must revert via the consumed+amount > cap check, not via uint128 overflow.
        vm.expectRevert(abi.encodeWithSelector(ISlippageCoverageVault.ExceedsWindowCap.selector));
        vm.prank(beneficiary);
        _vault.pullCoverage(address(_usdc), 1);
    }

    /* ============================ View functions ============================ */

    function test_getWindow_returnsZeroForUnconfiguredAsset() public view {
        SlippageCoverageVault.Window memory w = _vault.getWindow(address(_gho));
        assertEq(w.windowStart, 0);
        assertEq(w.windowSeconds, 0);
        assertEq(w.consumed, 0);
        assertEq(w.cap, 0);
    }

    function test_getPullCapPerTx_returnsZeroForUnconfiguredAsset() public view {
        assertEq(_vault.getPullCapPerTx(address(_gho)), 0);
    }

    function test_getBeneficiary_returnsImmutable() public view {
        assertEq(_vault.getBeneficiary(), beneficiary);
    }

    /* ============================ Helpers ============================ */

    function _configureUsdcCaps(uint256 perTxCap, uint256 windowCap, uint64 windowSeconds) internal {
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_usdc), perTxCap);
        vm.prank(operator);
        _vault.raiseWindowCap(address(_usdc), windowCap);
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_usdc), windowSeconds);
    }

    function _configureGhoCaps(uint256 perTxCap, uint256 windowCap, uint64 windowSeconds) internal {
        vm.prank(operator);
        _vault.raisePullCapPerTx(address(_gho), perTxCap);
        vm.prank(operator);
        _vault.raiseWindowCap(address(_gho), windowCap);
        vm.prank(operator);
        _vault.raiseWindowSeconds(address(_gho), windowSeconds);
    }

    function _fund(MockErc20 token, uint256 amount) internal {
        token.mint(address(_vault), amount);
    }
}
