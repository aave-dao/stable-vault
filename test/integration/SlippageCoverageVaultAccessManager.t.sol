// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

import {SlippageCoverageVault} from "src/periphery/SlippageCoverageVault.sol";

/// @dev Integration test for `SlippageCoverageVault` running behind a real `AccessManager`. Verifies that the new
/// `Multicall` inheritance lets the operator batch immediate tightening ops (Disabler-tier `lower*`) atomically and
/// also fire scheduled raises in a single tx after the raise delay elapses.
contract SlippageCoverageVaultAccessManagerIntegrationTest is Test {
    address internal admin = makeAddr("admin");
    address internal raiser = makeAddr("raiser");
    address internal lowerer = makeAddr("lowerer");
    address internal beneficiary = makeAddr("beneficiary");
    address internal asset = makeAddr("asset");

    AccessManager internal accessManager;
    SlippageCoverageVault internal vault;

    uint64 internal constant CAP_RAISER_ROLE = uint64(uint256(keccak256("aave.stable-vault.test.CapRaiser")));
    uint64 internal constant CAP_LOWERER_ROLE = uint64(uint256(keccak256("aave.stable-vault.test.CapLowerer")));

    uint32 internal constant RAISE_DELAY = 1 days;
    uint64 internal constant ONE_DAY = 1 days;

    uint256 internal constant DEFAULT_PER_TX_CAP = 1_000;
    uint256 internal constant DEFAULT_WINDOW_CAP = 10_000;

    function setUp() public {
        vm.warp(1_000_000);
        accessManager = new AccessManager(admin);
        vault = new SlippageCoverageVault(beneficiary, address(accessManager), 100, 5_000, false);

        vm.startPrank(admin);

        bytes4[] memory raiseSelectors = new bytes4[](3);
        raiseSelectors[0] = SlippageCoverageVault.raisePullCapPerTx.selector;
        raiseSelectors[1] = SlippageCoverageVault.raiseWindowCap.selector;
        // raiseWindowSeconds is tightening — kept on the same test role for simplicity; production wires it to a
        // no-delay operational role separate from the cap raiser.
        raiseSelectors[2] = SlippageCoverageVault.raiseWindowSeconds.selector;
        accessManager.setTargetFunctionRole(address(vault), raiseSelectors, CAP_RAISER_ROLE);

        bytes4[] memory lowerSelectors = new bytes4[](2);
        lowerSelectors[0] = SlippageCoverageVault.lowerPullCapPerTx.selector;
        lowerSelectors[1] = SlippageCoverageVault.lowerWindowCap.selector;
        accessManager.setTargetFunctionRole(address(vault), lowerSelectors, CAP_LOWERER_ROLE);

        // Grant raiser with no delay first to prime the caps, then re-grant with the actual raise delay.
        accessManager.grantRole(CAP_RAISER_ROLE, raiser, 0);
        accessManager.grantRole(CAP_LOWERER_ROLE, lowerer, 0);

        vm.stopPrank();

        vm.startPrank(raiser);
        vault.raisePullCapPerTx(asset, DEFAULT_PER_TX_CAP);
        vault.raiseWindowCap(asset, DEFAULT_WINDOW_CAP);
        vault.raiseWindowSeconds(asset, ONE_DAY);
        vm.stopPrank();

        vm.prank(admin);
        accessManager.grantRole(CAP_RAISER_ROLE, raiser, RAISE_DELAY);
    }

    /// @dev Disabler-tier incident response: lower both caps in one tx, no scheduling required.
    function test_atomicLower_bothCaps_succeedsWithoutScheduling() public {
        uint256 newPerTx = DEFAULT_PER_TX_CAP / 2;
        uint256 newWindow = DEFAULT_WINDOW_CAP / 2;
        bytes memory lowerPerTxData = abi.encodeCall(SlippageCoverageVault.lowerPullCapPerTx, (asset, newPerTx));
        bytes memory lowerWindowData = abi.encodeCall(SlippageCoverageVault.lowerWindowCap, (asset, newWindow));

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerPerTxData;
        calls[1] = lowerWindowData;

        vm.prank(lowerer);
        vault.multicall(calls);

        assertEq(vault.getPullCapPerTx(asset), newPerTx);
        assertEq(vault.getWindow(asset).cap, newWindow);
    }

    /// @dev MainAdmin-tier: schedule both raises, then fire them atomically after the delay.
    function test_atomicRaise_bothCaps_succeedsWhenBothScheduled() public {
        uint256 newPerTx = DEFAULT_PER_TX_CAP * 2;
        uint256 newWindow = DEFAULT_WINDOW_CAP * 2;
        bytes memory raisePerTxData = abi.encodeCall(SlippageCoverageVault.raisePullCapPerTx, (asset, newPerTx));
        bytes memory raiseWindowData = abi.encodeCall(SlippageCoverageVault.raiseWindowCap, (asset, newWindow));

        vm.startPrank(raiser);
        accessManager.schedule(address(vault), raisePerTxData, 0);
        accessManager.schedule(address(vault), raiseWindowData, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + RAISE_DELAY + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = raisePerTxData;
        calls[1] = raiseWindowData;

        vm.prank(raiser);
        vault.multicall(calls);

        assertEq(vault.getPullCapPerTx(asset), newPerTx);
        assertEq(vault.getWindow(asset).cap, newWindow);
    }

    /// @dev Mixed: lower per-tx (no schedule) + raise window (scheduled). Same caller would need both roles; this
    /// is the trilemma-violating case kept here purely to document the auth interaction.
    function test_atomicMixed_lowerPerTx_raiseWindow_succeedsWhenRaiseScheduled() public {
        vm.prank(admin);
        accessManager.grantRole(CAP_LOWERER_ROLE, raiser, 0);

        uint256 newPerTx = DEFAULT_PER_TX_CAP / 2;
        uint256 newWindow = DEFAULT_WINDOW_CAP * 2;
        bytes memory lowerPerTxData = abi.encodeCall(SlippageCoverageVault.lowerPullCapPerTx, (asset, newPerTx));
        bytes memory raiseWindowData = abi.encodeCall(SlippageCoverageVault.raiseWindowCap, (asset, newWindow));

        vm.prank(raiser);
        accessManager.schedule(address(vault), raiseWindowData, 0);

        vm.warp(block.timestamp + RAISE_DELAY + 1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerPerTxData;
        calls[1] = raiseWindowData;

        vm.prank(raiser);
        vault.multicall(calls);

        assertEq(vault.getPullCapPerTx(asset), newPerTx);
        assertEq(vault.getWindow(asset).cap, newWindow);
    }

    /// @dev Bubbling: when one inner call reverts, the whole multicall reverts.
    function test_atomicLower_revertsAndRollsBackIfOneCallFails() public {
        bytes memory lowerPerTxData =
            abi.encodeCall(SlippageCoverageVault.lowerPullCapPerTx, (asset, DEFAULT_PER_TX_CAP / 2));
        // Window cap "lower" but with a value greater than current — must revert with InvalidParameter.
        bytes memory invalidLowerWindowData =
            abi.encodeCall(SlippageCoverageVault.lowerWindowCap, (asset, DEFAULT_WINDOW_CAP * 2));

        bytes[] memory calls = new bytes[](2);
        calls[0] = lowerPerTxData;
        calls[1] = invalidLowerWindowData;

        vm.prank(lowerer);
        vm.expectRevert();
        vault.multicall(calls);

        // Per-tx cap was not lowered because the second call reverted the whole tx.
        assertEq(vault.getPullCapPerTx(asset), DEFAULT_PER_TX_CAP);
    }
}
