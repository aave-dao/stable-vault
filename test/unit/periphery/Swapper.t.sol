// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISlippageCoverageVault} from "src/interfaces/ISlippageCoverageVault.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {SlippageCoverageVault} from "src/periphery/SlippageCoverageVault.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {IMockDex, MockDex} from "test/mocks/MockDex.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";

contract SwapperTest is TestWithHelpers {
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    MockDex internal _mockDex;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;

    MockAccessManager internal _accessManager;
    SlippageCoverageVault internal _vault;
    Swapper internal _swapper;

    address allocator = makeAddr("ALLOCATOR");
    address rebalancer = makeAddr("REBALANCER");
    address operator = makeAddr("OPERATOR");

    uint256 internal constant LARGE_CAP = type(uint128).max - 1;

    function setUp() public {
        _mockDex = new MockDex();
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        _accessManager = new MockAccessManager(address(this));

        // Predict the Swapper address (vault then Swapper — both direct deploys).
        uint256 deployerNonce = vm.getNonce(address(this));
        address predictedSwapper = vm.computeCreateAddress(address(this), deployerNonce + 1);

        _vault = new SlippageCoverageVault(predictedSwapper, address(_accessManager), 100, 5_000, false);

        _swapper = new Swapper(allocator, address(_vault));
        require(address(_swapper) == predictedSwapper, "Swapper address mismatch");

        // Configure caps high enough for normal coverage tests; tighten in path-C tests.
        vm.startPrank(operator);
        _vault.raisePullCapPerTx(address(_mockGho), LARGE_CAP);
        _vault.raisePullCapPerTx(address(_mockUsdt), LARGE_CAP);
        _vault.raiseWindowCap(address(_mockGho), LARGE_CAP);
        _vault.raiseWindowSeconds(address(_mockGho), 1 days);
        _vault.raiseWindowCap(address(_mockUsdt), LARGE_CAP);
        _vault.raiseWindowSeconds(address(_mockUsdt), 1 days);
        // Allow up to 100% slippage in normal mode for the legacy slippage-coverage tests.
        _vault.setMaxSlippageBps(10_000);
        vm.stopPrank();
    }

    /* ---------------------------------- Constructor ---------------------------------- */

    function test_constructor_reverts_ifAllocatorIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Swapper(address(0), address(_vault));
    }

    function test_constructor_reverts_ifSlippageVaultIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        new Swapper(allocator, address(0));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(_swapper.owner(), allocator);
        assertEq(_swapper.getSlippageVault(), address(_vault));
    }

    /* ---------------------------------- Happy paths ---------------------------------- */

    function test_executeSwap_6decimalsInput_18decimalsOutput_noSlippage(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 minAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(minAmountOut > 0);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(0);

        bytes memory data =
            _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, 0);
        vm.prank(allocator);
        uint256 actualAmountOut =
            _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), minAmountOut);

        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_18decimalsInput_6decimalsOutput_noSlippage(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockGho), amountIn);
        uint256 divisor = 10 ** (AssetLib.getDecimals(address(_mockGho)) - AssetLib.getDecimals(address(_mockUsdt)));
        amountIn = amountIn / divisor * divisor;
        uint256 minAmountOut = amountIn.convertAssetDecimals(address(_mockGho), address(_mockUsdt));
        vm.assume(minAmountOut > 0);

        _mockTransferIntoSwapper(_mockGho, amountIn);
        _seedOutputToken(_mockUsdt, minAmountOut);
        _setSlippageBps(0);

        bytes memory data =
            _encodeDexSwapExactInputData(address(_mockGho), address(_mockUsdt), amountIn, minAmountOut, 0);
        vm.prank(allocator);
        uint256 actualAmountOut =
            _swapper.executeSwap(address(_mockGho), address(_mockUsdt), amountIn, rebalancer, data);

        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), minAmountOut);

        vm.prank(allocator);
        IERC20(_mockUsdt).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_pullsCoverageOnShortfall(uint256 amountIn, uint16 slippageToleranceBps) public {
        vm.assume(slippageToleranceBps <= 10_000);
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - slippageToleranceBps) / 10_000;
        vm.assume(minAmountOut > 0);

        uint256 amountNeededFromVault = amountOutIfNoSlippage - minAmountOut;
        vm.assume(amountNeededFromVault > 0);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(slippageToleranceBps);
        _fundVault(_mockGho, amountNeededFromVault);

        assertEq(_mockGho.balanceOf(address(_vault)), amountNeededFromVault);

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        uint256 actualAmountOut =
            _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), amountOutIfNoSlippage);
        assertEq(_mockGho.balanceOf(address(_vault)), 0);

        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_pullsCoverageOnShortfall_18in6out(uint256 amountIn, uint16 slippageToleranceBps) public {
        vm.assume(slippageToleranceBps <= 10_000);
        amountIn = _boundAssetAmount(address(_mockGho), amountIn);
        uint256 divisor = 10 ** (AssetLib.getDecimals(address(_mockGho)) - AssetLib.getDecimals(address(_mockUsdt)));
        amountIn = amountIn / divisor * divisor;
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockGho), address(_mockUsdt));
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - slippageToleranceBps) / 10_000;
        vm.assume(minAmountOut > 0);

        uint256 amountNeededFromVault = amountOutIfNoSlippage - minAmountOut;
        vm.assume(amountNeededFromVault > 0);

        _mockTransferIntoSwapper(_mockGho, amountIn);
        _seedOutputToken(_mockUsdt, minAmountOut);
        _setSlippageBps(slippageToleranceBps);
        _fundVault(_mockUsdt, amountNeededFromVault);

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockGho), address(_mockUsdt), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        uint256 actualAmountOut =
            _swapper.executeSwap(address(_mockGho), address(_mockUsdt), amountIn, rebalancer, data);

        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), amountOutIfNoSlippage);
        assertEq(_mockUsdt.balanceOf(address(_vault)), 0);

        vm.prank(allocator);
        IERC20(_mockUsdt).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_emitsSlippageCoveredWithVaultAsSource() public {
        uint16 slippageToleranceBps = 500; // 5%
        uint256 amountIn = 1_000_000;
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - slippageToleranceBps) / 10_000;
        uint256 slippageAmount = amountOutIfNoSlippage - minAmountOut;

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(slippageToleranceBps);
        _fundVault(_mockGho, slippageAmount);

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageToleranceBps
        );

        vm.expectEmit(true, true, false, true);
        emit Swapper.SlippageCovered(address(_vault), address(_mockGho), slippageAmount);
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);
    }

    function test_executeSwap_moreThanOneToOneOutput(uint256 amountIn, uint16 amountOutExtra) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 actualAmountOut = amountOutIfNoSlippage + uint256(amountOutExtra);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, actualAmountOut);
        _setSlippageBps(0);

        bytes memory data =
            _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), amountIn, amountOutIfNoSlippage, 0);
        vm.prank(allocator);
        uint256 actualAmountOutFromSwap =
            _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOutFromSwap);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_pullsCoverageInOverrideMode_largeSlippage() public {
        // Tighten normal-mode bound to 1% and rely on override (50%) to allow 30% slippage.
        vm.prank(operator);
        _vault.setMaxSlippageBps(1_00);

        vm.prank(operator);
        _vault.enableOverrideMode();

        uint16 slippageBps = 3_000; // 30%
        uint256 amountIn = 1_000_000;
        uint256 expected = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 minAmountOut = expected * (10_000 - slippageBps) / 10_000;
        uint256 slippageAmount = expected - minAmountOut;

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(slippageBps);
        _fundVault(_mockGho, slippageAmount);

        bytes memory data =
            _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageBps);
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        assertEq(_mockGho.balanceOf(address(_vault)), 0);
    }

    /* ---------------------------------- Vault binding & assetIn checks ---------------------------------- */

    /// @dev target = vault would call `pullCoverage` inside the loop bypassing the slippage cap.
    function test_executeSwap_reverts_ifTargetIsVault() public {
        address[] memory targets = new address[](1);
        targets[0] = address(_vault);
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeCall(ISlippageCoverageVault.pullCoverage, (address(_mockGho), 1));
        bytes memory data = abi.encode(targets, callDatas, uint16(0));

        _mockTransferIntoSwapper(_mockUsdt, 100);

        vm.expectRevert(abi.encodeWithSelector(Swapper.BadTarget.selector));
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), 100, rebalancer, data);
    }

    /// @dev Manager sets tolerance above the vault-bounded max in normal mode.
    function test_executeSwap_reverts_ifSlippageToleranceAboveMax_normalMode() public {
        // Tighten max to 1% and request 2%.
        vm.prank(operator);
        _vault.setMaxSlippageBps(1_00);

        bytes memory data = _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), 100, 0, 200);

        _mockTransferIntoSwapper(_mockUsdt, 100);
        vm.expectRevert(abi.encodeWithSelector(Swapper.SlippageToleranceTooHigh.selector));
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), 100, rebalancer, data);
    }

    /// @dev Override mode: override max is the upper bound.
    function test_executeSwap_reverts_ifSlippageToleranceAboveMax_overrideMode() public {
        vm.prank(operator);
        _vault.setOverrideMaxSlippageBps(2_000); // 20%
        vm.prank(operator);
        _vault.enableOverrideMode();

        bytes memory data = _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), 100, 0, 2_001);

        _mockTransferIntoSwapper(_mockUsdt, 100);
        vm.expectRevert(abi.encodeWithSelector(Swapper.SlippageToleranceTooHigh.selector));
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), 100, rebalancer, data);
    }

    /// @dev Empty target loop: `assetIn` is never consumed. The full `amountIn` is returned to the vault (paying it
    /// back for the over-pull at peg + matching decimals) and `AssetInSwept` is emitted. assetOut is pre-seeded so
    /// the slippage check passes.
    function test_executeSwap_sweepsAssetIn_ifFullyLeftover() public {
        uint256 amountIn = 100;
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _mockGho.mint(address(_swapper), expectedAmountOut); // pre-seed so amountOut == expected

        address[] memory targets = new address[](0);
        bytes[] memory callDatas = new bytes[](0);
        bytes memory data = abi.encode(targets, callDatas, uint16(0));

        uint256 vaultAssetInBefore = _mockUsdt.balanceOf(address(_vault));

        vm.expectEmit(true, false, false, true, address(_swapper));
        emit Swapper.AssetInSwept(address(_vault), address(_mockUsdt), amountIn);
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        assertEq(_mockUsdt.balanceOf(address(_vault)) - vaultAssetInBefore, amountIn, "leftover not returned to vault");
        assertEq(_mockUsdt.balanceOf(address(_swapper)), 0, "assetIn still on swapper");
    }

    /// @dev Partial venue consumption: half of `amountIn` is sent to an external recipient inside the loop, half
    /// stays in the Swapper. The half left on the Swapper is returned to the vault. assetOut is pre-seeded so the
    /// slippage check passes. The half routed away is the residual that monitoring + vault caps bound under a
    /// compromised rebalancer; this test only asserts the return semantics.
    function test_executeSwap_sweepsAssetIn_ifPartiallyLeftover() public {
        uint256 amountIn = 100;
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _mockGho.mint(address(_swapper), expectedAmountOut);

        address dust = makeAddr("dust");
        address[] memory targets = new address[](1);
        targets[0] = address(_mockUsdt);
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(IERC20.transfer.selector, dust, amountIn / 2);
        bytes memory data = abi.encode(targets, callDatas, uint16(0));

        uint256 vaultAssetInBefore = _mockUsdt.balanceOf(address(_vault));

        vm.expectEmit(true, false, false, true, address(_swapper));
        emit Swapper.AssetInSwept(address(_vault), address(_mockUsdt), amountIn / 2);
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        assertEq(
            _mockUsdt.balanceOf(address(_vault)) - vaultAssetInBefore, amountIn / 2, "leftover not returned to vault"
        );
        assertEq(_mockUsdt.balanceOf(dust), amountIn / 2, "dust did not receive its half");
        assertEq(_mockUsdt.balanceOf(address(_swapper)), 0, "assetIn still on swapper");
    }

    /// @dev Donations of the same asset as `assetIn` are swept into the vault on the next rebalance — the Swapper
    /// has no rescue path of its own, so pushing everything out is the safer default. An attacker who pre-funds the
    /// Swapper with `assetIn` before a rebalance therefore donates those tokens to the coverage pool; not a grief
    /// (no funds lost) and not a swap-flow inflation (the swap accounting is unchanged).
    function test_executeSwap_succeeds_whenAssetInDonatedBeforeCall(uint256 donation) public {
        uint256 amountIn = 100;
        donation = bound(donation, 1, 1_000_000); // arbitrary non-zero donation
        uint256 minAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(minAmountOut > 0);

        // Pre-fund the Swapper with `donation` of assetIn (the would-be grief).
        _mockUsdt.mint(address(_swapper), donation);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(0);

        uint256 vaultAssetInBefore = _mockUsdt.balanceOf(address(_vault));

        bytes memory data =
            _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, 0);
        vm.expectEmit(true, false, false, true, address(_swapper));
        emit Swapper.AssetInSwept(address(_vault), address(_mockUsdt), donation);
        vm.prank(allocator);
        uint256 actualAmountOut =
            _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        // The DEX consumed `amountIn` and the donation was returned to the vault; the Swapper holds nothing.
        assertEq(_mockUsdt.balanceOf(address(_swapper)), 0, "donation not swept off the swapper");
        assertEq(
            _mockUsdt.balanceOf(address(_vault)) - vaultAssetInBefore, donation, "donation not landed on the vault"
        );
        assertEq(actualAmountOut, minAmountOut);
    }

    /// @dev The vault-side `CoverageFunded` event is what monitoring would observe for a return; pin it alongside
    /// the Swapper's own `AssetInSwept` so both legs of the audit trail are exercised.
    function test_executeSwap_returnsLeftoverAssetIn_emitsCoverageFundedFromVault() public {
        uint256 amountIn = 100;
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _mockGho.mint(address(_swapper), expectedAmountOut);

        address[] memory targets = new address[](0);
        bytes[] memory callDatas = new bytes[](0);
        bytes memory data = abi.encode(targets, callDatas, uint16(0));

        vm.expectEmit(true, true, false, true, address(_vault));
        emit SlippageCoverageVault.CoverageFunded(address(_mockUsdt), address(_swapper), amountIn);
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);
    }

    /// @dev `forceApprove(amount)` followed by `transferFrom(amount)` must net to zero allowance — otherwise a stale
    /// allowance from the Swapper to the vault would persist between rebalances.
    function test_executeSwap_returnsLeftoverAssetIn_leavesNoResidualAllowance() public {
        uint256 amountIn = 100;
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _mockGho.mint(address(_swapper), expectedAmountOut);

        address[] memory targets = new address[](0);
        bytes[] memory callDatas = new bytes[](0);
        bytes memory data = abi.encode(targets, callDatas, uint16(0));

        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        assertEq(_mockUsdt.allowance(address(_swapper), address(_vault)), 0, "stale allowance from swapper to vault");
    }

    /// @dev Combined path: the DEX under-consumes `assetIn` (residual stays on the Swapper) AND under-delivers
    /// `assetOut` (slippage check pulls coverage).
    function test_executeSwap_pullsCoverageAndReimbursesLeftover_inSameSwap() public {
        uint256 amountIn = 1_000_000; // 1 USDT (6 decimals)
        uint256 leftoverIn = 100_000; // 0.1 USDT residual the DEX is told to skip
        uint256 swapAmount = amountIn - leftoverIn;
        uint16 dexSlippageBps = 1_000; // 10% slippage on the consumed portion
        uint16 swapperToleranceBps = 2_000; // 20% — admits the shortfall computed against the *full* amountIn

        uint256 expectedAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 dexOutput =
            swapAmount.convertAssetDecimals(address(_mockUsdt), address(_mockGho)) * (10_000 - dexSlippageBps) / 10_000;
        uint256 slippageShortfall = expectedAmountOut - dexOutput;

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, dexOutput);
        _setSlippageBps(dexSlippageBps);
        _fundVault(_mockGho, slippageShortfall);

        uint256 vaultAssetInBefore = _mockUsdt.balanceOf(address(_vault));
        uint256 vaultAssetOutBefore = _mockGho.balanceOf(address(_vault));

        // Route only `swapAmount` through the DEX; the remaining `leftoverIn` stays on the Swapper.
        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockUsdt), address(_mockGho), swapAmount, dexOutput, swapperToleranceBps
        );

        // Order matches the Swapper flow: pullCoverage -> SlippageCovered -> reimburseCoverage -> AssetInSwept.
        vm.expectEmit(true, false, false, true, address(_vault));
        emit ISlippageCoverageVault.CoveragePulled(address(_mockGho), slippageShortfall, false);
        vm.expectEmit(true, true, false, true, address(_swapper));
        emit Swapper.SlippageCovered(address(_vault), address(_mockGho), slippageShortfall);
        vm.expectEmit(true, true, false, true, address(_vault));
        emit SlippageCoverageVault.CoverageFunded(address(_mockUsdt), address(_swapper), leftoverIn);
        vm.expectEmit(true, true, false, true, address(_swapper));
        emit Swapper.AssetInSwept(address(_vault), address(_mockUsdt), leftoverIn);

        vm.prank(allocator);
        uint256 actualAmountOut =
            _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);

        assertEq(actualAmountOut, expectedAmountOut, "actualAmountOut != expectedAmountOut");
        assertEq(_mockGho.balanceOf(address(_swapper)), expectedAmountOut, "swapper assetOut balance mismatch");
        assertEq(_mockUsdt.balanceOf(address(_swapper)), 0, "leftover assetIn still on swapper");
        assertEq(
            vaultAssetOutBefore - _mockGho.balanceOf(address(_vault)),
            slippageShortfall,
            "vault assetOut not decreased by shortfall"
        );
        assertEq(
            _mockUsdt.balanceOf(address(_vault)) - vaultAssetInBefore,
            leftoverIn,
            "vault assetIn not increased by residual"
        );
    }

    function test_executeSwap_reverts_ifTargetsAndCallDatasLengthMismatch() public {
        address[] memory targets = new address[](2);
        targets[0] = address(_mockUsdt);
        targets[1] = address(_mockDex);
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(IERC20.approve.selector, address(_mockDex), 100);
        bytes memory data = abi.encode(targets, callDatas, uint16(0));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector));
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), 100, rebalancer, data);
    }

    /* ---------------------------------- Existing reverts ---------------------------------- */

    function test_executeSwap_reverts_6decimalsInput_18decimalsOutput_slippage(
        uint256 amountIn,
        uint16 slippageToleranceBps
    ) public {
        vm.assume(slippageToleranceBps < type(uint16).max);
        uint16 actualSlippage = slippageToleranceBps + 1;
        vm.assume(actualSlippage <= 10_000);
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(amountOutIfNoSlippage > 0);
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - actualSlippage) / 10_000;
        vm.assume(minAmountOut > 0);

        uint256 amountNeededFromVault = amountOutIfNoSlippage - minAmountOut;
        vm.assume(amountNeededFromVault > 0);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(actualSlippage);
        _fundVault(_mockGho, amountNeededFromVault);

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(Swapper.SlippageToleranceExceeded.selector));
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);
    }

    function test_executeSwap_reverts_ifCallToTargetFailed() public {
        uint256 amountIn = 100;

        vm.mockCallRevert(
            address(_mockDex),
            abi.encodeWithSelector(
                IMockDex.swapExactInput.selector, address(_mockUsdt), address(_mockGho), amountIn, 0
            ),
            abi.encodeWithSelector(IMockDex.InsufficientLiquidity.selector)
        );

        bytes memory data = _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), amountIn, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Swapper.CallToTargetFailed.selector));
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, rebalancer, data);
    }

    function test_executeSwap_reverts_ifNotOwner(address caller) public {
        vm.assume(caller != allocator);
        bytes memory data = abi.encode(keccak256("test"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), 100, rebalancer, data);
    }

    /* ---------------------------------- Helpers ---------------------------------- */

    function _mockTransferIntoSwapper(IMockErc20 token, uint256 amount) internal {
        MockNonStandardErc20(address(token)).mint(address(_swapper), amount);
    }

    function _seedOutputToken(IMockErc20 token, uint256 amount) internal {
        token.mint(address(_mockDex), amount);
    }

    function _setSlippageBps(uint16 slippageBps) internal {
        _mockDex.setSlippageBps(slippageBps);
    }

    function _fundVault(IMockErc20 token, uint256 amount) internal {
        token.mint(address(_vault), amount);
    }

    function _encodeDexSwapExactInputData(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16 slippageToleranceBps
    ) internal view returns (bytes memory) {
        bytes memory approveDexData = abi.encodeWithSelector(IERC20.approve.selector, address(_mockDex), amountIn);
        bytes memory dexData =
            abi.encodeWithSelector(IMockDex.swapExactInput.selector, tokenIn, tokenOut, amountIn, minAmountOut);

        address[] memory targets = new address[](2);
        targets[0] = tokenIn;
        targets[1] = address(_mockDex);
        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = approveDexData;
        callDatas[1] = dexData;
        return abi.encode(targets, callDatas, slippageToleranceBps);
    }
}
