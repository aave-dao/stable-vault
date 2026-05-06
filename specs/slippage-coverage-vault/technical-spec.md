# SlippageCoverageVault — Technical Specification

## Overview

Replace `OwnedMulticall` as the source of slippage-coverage funds for Allocator rebalance swaps with a purpose-built, push-based `SlippageCoverageVault`. Companion change: harden the existing `Swapper` to bind the vault immutably, bound `slippageToleranceBps`, prevent target-loop abuse, and assert zero-leftover `assetIn`. Allocator stays unchanged.

This closes Stermi I-06 and I-14, Certora M-01 (capital-isolation portion; capital sizing remains treasury's lane), Recon-Fuzz #22 in full, and Recon-Fuzz #33 (Swapper line) in full.

## Problem Statement

Coverage funds for rebalance swaps live in `OwnedMulticall` (`src/periphery/OwnedMulticall.sol`). Treasury funds it; manager spends it later via `Allocator.rebalance`. Between funding and spending, the full balance sits inside `OwnedMulticall`, which exposes unrestricted `target.call(callData)` to its owner (the manager EOA / contract wallet). A compromised manager has four independent drain paths:

| Path | Vector | Allocator 1:1 catches? |
|---|---|---|
| **A** Direct drain | `aggregate3([{token, transfer(attacker, balance)}])` — bypasses Allocator entirely | No — never enters `_swap` |
| **B** Malicious swapper | Manager passes evil `swap.swapper`. Evil contract steals `assetIn` (line 414 of `Allocator.sol`), funds `assetOut` return from coverage source. 1:1 invariant on `assetOut` is satisfied because coverage tops up. | Bypassed — invariant is on `assetOut` only, not `assetIn` |
| **C** Legit swapper, manipulated params | (1) `transferFrom(coverage, attacker)` injected in target loop. (2) `slippageToleranceBps = 99%` to route most of `expectedAmountOut` through coverage. (3) `assetIn` redirected inside loop and coverage funds the return leg. (4) `targets[i] = vault` to trigger pulls inline. | Asymmetric — only `assetOut` checked; (3) bypasses |
| **D** Approval bypass | Manager pre-approves attacker via OwnedMulticall; later attacker drains via `transferFrom`. Bypasses Allocator entirely. | No |

Allocator's only check is `amountOut >= expectedAmountOut` on the *return leg* (`Allocator.sol:419-421`). This is asymmetric — `assetIn` is not reconciled. Paths A and D do not enter `_swap` at all. The audit baseline relies on manager trust + 1-hour guardian SLA (Assumption #17), but the coverage capital has no secondary protection.

Recon-Fuzz #33 (Gallo, 2026-05-05) re-affirmed independently: rate limits should sit on the `slippageCoverageSource`, not the swap volume. Limiting a swap is operationally fragile (depeg events need to swap); limiting the coverage source bounds total loss without blocking emergency operations.

## Proposed Solution

Three changes shipped together:

1. **`SlippageCoverageVault`** — new contract holding coverage capital. Push-based outflow (`safeTransfer` only, never `approve`). Immutable `SLIPPAGE_RECIPIENT` (the bound Swapper) is the sole authorized puller. Per-asset per-tx cap + per-asset sliding-window cap. Override mode (manual flip by guardian, no TTL) bypasses caps for emergency rebalance.
2. **`Swapper` hardenings** — immutable `SLIPPAGE_VAULT`. Removed `slippageCoverageSource` from `SlippageParams`. Three new asserts: target ≠ vault, `slippageToleranceBps` ≤ governance-tunable max, `balanceOf(assetIn) == 0` after target loop.
3. **No Allocator changes**. The Allocator's 1:1 invariant remains the gate on the return leg. The asymmetric `assetIn` reconciliation is closed by the Swapper's zero-leftover assert (Hardening 3).

The design is deliberately minimal: structural binding (immutable recipient), structural separation (no allowance surface), structural limits (caps), structural separation of duty (guardian role distinct from rebalancer role).

## Technical Approach

### Architecture

```
                    ┌─────────────────────────────┐
                    │       SlippageCoverageVault │  AccessManagedUpgradeable
                    │  ─────────────────────────  │  ERC-7201 storage
                    │  immutable SLIPPAGE_RECIPIENT  // bound Swapper
                    │  pullCapPerTx[asset]        │
                    │  windowState[asset]         │
                    │  overrideMode (bool)        │
                    │  maxSlippageBps             │  governance-tunable
                    │  overrideMaxSlippageBps     │  governance-tunable
                    └────────────┬────────────────┘
                       safeTransfer (push)
                                 │
                                 ▼
   ┌────────────┐    ┌────────────────────────┐
   │ Allocator  │───▶│   Swapper              │  immutable SLIPPAGE_VAULT
   │  (no change)│    │  ─────────────────    │
   └────────────┘    │  target loop + 3 asserts:
                    │   - targets[i] != SLIPPAGE_VAULT
                    │   - slippageBps <= maxBps
                    │   - balanceOf(assetIn) == 0
                    │  pullCoverage on shortfall
                    └────────────────────────┘
```

`OwnedMulticall` is no longer a coverage source. It remains as a batch-execution proxy for the manager (`rebalance`, `topUp`, etc.) but holds no tokens. The drain paths A and D close because there is nothing to drain.

### Component inventory

#### New: `src/interfaces/ISlippageCoverageVault.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

interface ISlippageCoverageVault {
    /// @notice Emitted when coverage is pulled by the bound recipient.
    event CoveragePulled(address indexed asset, uint256 amount, bool overrideMode);
    event OverrideModeSet(bool enabled);
    event PullCapPerTxRaised(address indexed asset, uint256 oldCap, uint256 newCap);
    event PullCapPerTxLowered(address indexed asset, uint256 oldCap, uint256 newCap);
    event WindowCapRaised(address indexed asset, uint256 oldCap, uint256 newCap, uint64 windowSeconds);
    event WindowCapLowered(address indexed asset, uint256 oldCap, uint256 newCap, uint64 windowSeconds);
    event MaxSlippageBpsSet(uint16 oldBps, uint16 newBps);
    event OverrideMaxSlippageBpsSet(uint16 oldBps, uint16 newBps);
    event ToppedUp(address indexed asset, address indexed from, uint256 amount);
    event Swept(address indexed asset, address indexed to, uint256 amount);

    /// @notice Thrown when a non-recipient attempts to pull coverage.
    /// @custom:selector 0x_______
    error OnlyRecipient();

    /// @notice Thrown when amount exceeds per-tx cap in normal mode.
    /// @custom:selector 0x_______
    error ExceedsPerTxCap();

    /// @notice Thrown when amount + window-consumed exceeds window cap in normal mode.
    /// @custom:selector 0x_______
    error ExceedsWindowCap();

    /// @notice Window state for sliding cap.
    struct Window {
        uint64  windowStart;
        uint64  windowSeconds;
        uint128 consumed;
        uint128 cap;
    }

    function pullCoverage(address asset, uint256 amount) external;

    function setOverrideMode(bool enabled) external;

    function raisePullCapPerTx(address asset, uint256 newCap) external;
    function lowerPullCapPerTx(address asset, uint256 newCap) external;
    function raiseWindowCap(address asset, uint256 newCap, uint64 windowSeconds) external;
    function lowerWindowCap(address asset, uint256 newCap, uint64 windowSeconds) external;
    function setMaxSlippageBps(uint16 newBps) external;
    function setOverrideMaxSlippageBps(uint16 newBps) external;

    function topUp(address asset, uint256 amount) external;
    function sweep(address asset, uint256 amount, address to) external;

    function getRecipient() external view returns (address);
    function getOverrideMode() external view returns (bool);
    function getPullCapPerTx(address asset) external view returns (uint256);
    function getWindow(address asset) external view returns (Window memory);
    function getMaxSlippageBps() external view returns (uint16);
    function getOverrideMaxSlippageBps() external view returns (uint16);
}
```

#### New: `src/periphery/SlippageCoverageVault.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManagedUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransientUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISlippageCoverageVault} from "src/interfaces/ISlippageCoverageVault.sol";
import {Errors} from "src/types/Errors.sol";

contract SlippageCoverageVault is
    Initializable,
    AccessManagedUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    ISlippageCoverageVault
{
    using SafeERC20 for IERC20;

    /// @dev Bound puller. Set at construction; never changed.
    address public immutable SLIPPAGE_RECIPIENT;

    /// @custom:storage-location erc7201:aave.storage.SlippageCoverageVault
    struct SlippageCoverageVaultStorage {
        bool overrideMode;
        uint16 maxSlippageBps;
        uint16 overrideMaxSlippageBps;
        mapping(address asset => uint256) pullCapPerTx;
        mapping(address asset => Window) windowByAsset;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.SlippageCoverageVault")) - 1))
    //   & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_SLIPPAGE_COVERAGE_VAULT =
        0x___________________________________________________________________; // compute offline

    function $storage() private pure returns (SlippageCoverageVaultStorage storage _s) {
        assembly { _s.slot := STORAGE_SLOT_SLIPPAGE_COVERAGE_VAULT }
    }

    constructor(address slippageRecipient) {
        require(slippageRecipient != address(0), Errors.ZeroAddress());
        SLIPPAGE_RECIPIENT = slippageRecipient;
        _disableInitializers();
    }

    function initialize(
        address authority,
        uint16  initialMaxSlippageBps,
        uint16  initialOverrideMaxSlippageBps
    ) external initializer {
        __AccessManaged_init(authority);
        __ReentrancyGuardTransient_init();
        SlippageCoverageVaultStorage storage $ = $storage();
        $.maxSlippageBps         = initialMaxSlippageBps;
        $.overrideMaxSlippageBps = initialOverrideMaxSlippageBps;
        emit MaxSlippageBpsSet(0, initialMaxSlippageBps);
        emit OverrideMaxSlippageBpsSet(0, initialOverrideMaxSlippageBps);
    }

    /// @inheritdoc ISlippageCoverageVault
    function pullCoverage(address asset, uint256 amount) external nonReentrant {
        require(msg.sender == SLIPPAGE_RECIPIENT, OnlyRecipient());
        require(amount > 0, Errors.ZeroAmount());

        SlippageCoverageVaultStorage storage $ = $storage();
        bool inOverride = $.overrideMode;

        if (!inOverride) {
            require(amount <= $.pullCapPerTx[asset], ExceedsPerTxCap());
            _consumeWindow($, asset, amount);
        }

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit CoveragePulled(asset, amount, inOverride);
    }

    function _consumeWindow(SlippageCoverageVaultStorage storage $, address asset, uint256 amount) private {
        Window memory w = $.windowByAsset[asset];
        require(w.cap > 0 && w.windowSeconds > 0, ExceedsWindowCap()); // unconfigured rejects
        if (block.timestamp >= uint256(w.windowStart) + uint256(w.windowSeconds)) {
            w.windowStart = uint64(block.timestamp);
            w.consumed    = 0;
        }
        require(uint256(w.consumed) + amount <= uint256(w.cap), ExceedsWindowCap());
        w.consumed = uint128(uint256(w.consumed) + amount);
        $.windowByAsset[asset] = w;
    }

    /* --- governance setters: directional ACL (raise vs lower split by selector) --- */

    function setOverrideMode(bool enabled) external restricted {
        $storage().overrideMode = enabled;
        emit OverrideModeSet(enabled);
    }

    function raisePullCapPerTx(address asset, uint256 newCap) external restricted {
        SlippageCoverageVaultStorage storage $ = $storage();
        uint256 old = $.pullCapPerTx[asset];
        require(newCap > old, Errors.InvalidParameter());
        $.pullCapPerTx[asset] = newCap;
        emit PullCapPerTxRaised(asset, old, newCap);
    }

    function lowerPullCapPerTx(address asset, uint256 newCap) external restricted {
        SlippageCoverageVaultStorage storage $ = $storage();
        uint256 old = $.pullCapPerTx[asset];
        require(newCap < old, Errors.InvalidParameter());
        $.pullCapPerTx[asset] = newCap;
        emit PullCapPerTxLowered(asset, old, newCap);
    }

    function raiseWindowCap(address asset, uint256 newCap, uint64 windowSeconds) external restricted {
        require(windowSeconds > 0, Errors.InvalidParameter());
        require(newCap <= type(uint128).max, Errors.InvalidAmount());
        SlippageCoverageVaultStorage storage $ = $storage();
        Window memory w = $.windowByAsset[asset];
        require(newCap > w.cap, Errors.InvalidParameter());
        w.cap           = uint128(newCap);
        w.windowSeconds = windowSeconds;
        $.windowByAsset[asset] = w;
        emit WindowCapRaised(asset, w.cap, newCap, windowSeconds);
    }

    function lowerWindowCap(address asset, uint256 newCap, uint64 windowSeconds) external restricted {
        require(windowSeconds > 0, Errors.InvalidParameter());
        require(newCap <= type(uint128).max, Errors.InvalidAmount());
        SlippageCoverageVaultStorage storage $ = $storage();
        Window memory w = $.windowByAsset[asset];
        require(newCap < w.cap, Errors.InvalidParameter());
        w.cap           = uint128(newCap);
        w.windowSeconds = windowSeconds;
        $.windowByAsset[asset] = w;
        emit WindowCapLowered(asset, w.cap, newCap, windowSeconds);
    }

    function setMaxSlippageBps(uint16 newBps) external restricted {
        SlippageCoverageVaultStorage storage $ = $storage();
        uint16 old = $.maxSlippageBps;
        $.maxSlippageBps = newBps;
        emit MaxSlippageBpsSet(old, newBps);
    }

    function setOverrideMaxSlippageBps(uint16 newBps) external restricted {
        SlippageCoverageVaultStorage storage $ = $storage();
        uint16 old = $.overrideMaxSlippageBps;
        $.overrideMaxSlippageBps = newBps;
        emit OverrideMaxSlippageBpsSet(old, newBps);
    }

    function topUp(address asset, uint256 amount) external restricted nonReentrant {
        require(amount > 0, Errors.ZeroAmount());
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit ToppedUp(asset, msg.sender, amount);
    }

    function sweep(address asset, uint256 amount, address to) external restricted nonReentrant {
        require(to != address(0), Errors.ZeroAddress());
        require(amount > 0, Errors.ZeroAmount());
        IERC20(asset).safeTransfer(to, amount);
        emit Swept(asset, to, amount);
    }

    /* --- views --- */
    function getRecipient()                    external view returns (address)        { return SLIPPAGE_RECIPIENT; }
    function getOverrideMode()                 external view returns (bool)           { return $storage().overrideMode; }
    function getPullCapPerTx(address asset)    external view returns (uint256)        { return $storage().pullCapPerTx[asset]; }
    function getWindow(address asset)          external view returns (Window memory)  { return $storage().windowByAsset[asset]; }
    function getMaxSlippageBps()               external view returns (uint16)         { return $storage().maxSlippageBps; }
    function getOverrideMaxSlippageBps()       external view returns (uint16)         { return $storage().overrideMaxSlippageBps; }
}
```

Notes:
- ERC-7201 slot constant is computed offline per repo convention. Comment carries the formula.
- `pullCoverage` has no `restricted` modifier; access is gated structurally by the `msg.sender == SLIPPAGE_RECIPIENT` check on the immutable address.
- `nonReentrant` on `pullCoverage`, `topUp`, `sweep` — defense in depth against ERC-777-style transfer callbacks (cheap with transient storage).
- State updates **before** `safeTransfer` (window consume → transfer; topUp uses transferFrom which is safe under the recipient gate).
- `pullCapPerTx == 0` rejects all pulls (default state). Vault is unusable until governance sets per-asset caps post-deploy. Documented in deployment ticket.
- `Window.cap == 0` rejects all pulls (default state).
- FoT / rebasing tokens: rejected at registry level (governance-curated asset list per repo precedent). Spec does not add balance-delta accounting; document explicitly.

#### Modified: `src/interfaces/ISwapper.sol`

```solidity
// New (moved from Swapper.sol; slippageCoverageSource removed):
struct SlippageParams {
    uint16 slippageToleranceBps;
}

// New errors:
/// @notice Thrown when a target in the call loop equals the bound vault.
/// @custom:selector 0x_______
error BadTarget();

/// @notice Thrown when slippage tolerance exceeds the on-chain bound.
/// @custom:selector 0x_______
error SlippageToleranceTooHigh();

/// @notice Thrown when assetIn is not fully consumed by the call loop.
/// @custom:selector 0x_______
error AssetInLeftOver();
```

#### Modified: `src/periphery/Swapper.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISwapper} from "src/interfaces/ISwapper.sol";
import {ISlippageCoverageVault} from "src/interfaces/ISlippageCoverageVault.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

contract Swapper is Ownable, ReentrancyGuard, ISwapper {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    address public immutable SLIPPAGE_VAULT;

    constructor(address allocator, address slippageVault) Ownable(allocator) {
        require(allocator      != address(0), Errors.ZeroAddress());
        require(slippageVault  != address(0), Errors.ZeroAddress());
        SLIPPAGE_VAULT = slippageVault;
    }

    function executeSwap(address assetIn, address assetOut, uint256 amountIn, address /* msgSender */, bytes memory data)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        (address[] memory targets, bytes[] memory callDatas, ISwapper.SlippageParams memory slippageParams) =
            abi.decode(data, (address[], bytes[], ISwapper.SlippageParams));
        require(targets.length == callDatas.length, Errors.InvalidParameter());

        // Hardening 1: targets cannot be the vault.
        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i] != SLIPPAGE_VAULT, ISwapper.BadTarget());
            (bool ok,) = targets[i].call(callDatas[i]);
            require(ok, ISwapper.CallToTargetFailed());
        }

        uint256 amountOut         = IERC20(assetOut).balanceOf(address(this));
        uint256 expectedAmountOut = amountIn.convertAssetDecimals(assetIn, assetOut);

        // Hardening 2: bound slippage tolerance against governance-tunable max read from vault.
        uint16 maxBps = ISlippageCoverageVault(SLIPPAGE_VAULT).getOverrideMode()
            ? ISlippageCoverageVault(SLIPPAGE_VAULT).getOverrideMaxSlippageBps()
            : ISlippageCoverageVault(SLIPPAGE_VAULT).getMaxSlippageBps();
        require(slippageParams.slippageToleranceBps <= maxBps, ISwapper.SlippageToleranceTooHigh());

        if (amountOut < expectedAmountOut) {
            require(
                _minToleratedAmountOut(expectedAmountOut, slippageParams.slippageToleranceBps) <= amountOut,
                ISwapper.SlippageToleranceExceeded()
            );
            uint256 slippageAmount = expectedAmountOut - amountOut;
            ISlippageCoverageVault(SLIPPAGE_VAULT).pullCoverage(assetOut, slippageAmount);
            emit ISwapper.SlippageCovered(SLIPPAGE_VAULT, assetOut, slippageAmount);
            amountOut = expectedAmountOut;
        }

        // Hardening 3: assetIn fully consumed by the loop.
        require(IERC20(assetIn).balanceOf(address(this)) == 0, ISwapper.AssetInLeftOver());

        IERC20(assetOut).forceApprove(msg.sender, amountOut);
        return amountOut;
    }

    function _minToleratedAmountOut(uint256 expectedAmountOut, uint16 slippageToleranceBps)
        internal pure returns (uint256)
    {
        return expectedAmountOut * (Constants.MAX_BPS - slippageToleranceBps) / Constants.MAX_BPS;
    }
}
```

Notes:
- `SLIPPAGE_VAULT` immutable; rotation requires Swapper redeploy + AccessManager re-wire.
- `targets.length == callDatas.length` check — added defensively (was missing in current Swapper).
- `SlippageCovered` event still emitted with the vault as the indexed coverage source — preserves audit-log shape.
- The two `getMaxSlippageBps`/`getOverrideMaxSlippageBps` reads inside `executeSwap` cost two SLOADs each; acceptable in the slippage path.

#### Modified: `src/core/Allocator.sol`

No code changes. The `_swap` 1:1 invariant remains. The asymmetric `assetIn` reconciliation gap is closed by Swapper Hardening 3.

#### Modified: `src/core/IAllocator.sol`

No interface changes.

### Implementation phases

#### Phase 1: Contract foundation

- [ ] Create `src/interfaces/ISlippageCoverageVault.sol` (events, errors, struct, interface).
- [ ] Compute and document the ERC-7201 slot constant.
- [ ] Create `src/periphery/SlippageCoverageVault.sol` with `pullCoverage`, governance setters (raise/lower split), `topUp`, `sweep`, views.
- [ ] Update `src/interfaces/ISwapper.sol`: move `SlippageParams` from contract, drop `slippageCoverageSource`, add new errors.
- [ ] Update `src/periphery/Swapper.sol`: immutable `SLIPPAGE_VAULT`, three hardenings, vault `pullCoverage` call, target/length check.

Success criteria: contracts compile under `forge build --deny warnings`. New errors carry `@custom:selector` natspec.

#### Phase 2: Tests

- [ ] `test/unit/periphery/SlippageCoverageVault.t.sol` — full vault unit suite (see Test Plan below).
- [ ] Update `test/unit/periphery/Swapper.t.sol` — update existing tests for new constructor, add hardening tests, drop tests that depended on `slippageCoverageSource` field.
- [ ] Update `test/unit/periphery/OwnedMulticall.t.sol::test_rebalance_viaOwnedMulticall_swapWithSlippageCoverage` — coverage now flows from vault, manager's `aggregate3` no longer pre-approves Swapper.
- [ ] Update mocks: `test/mocks/MockSwapper.sol` if its constructor signature is touched anywhere downstream.

Success criteria: `forge test` passes (10_000 fuzz runs per `foundry.toml`).

#### Phase 3: Deployment wiring

- [ ] `script/base/Create3AddressBook.sol`:
  - Add `SLIPPAGE_COVERAGE_VAULT_SALT_SEED = "aave.stable-vault.SlippageCoverageVault"`.
  - Add `getSlippageCoverageVaultAddress(deployer)`.
- [ ] `script/base/EarningChainDeployment.sol` and `script/base/AccountingChainDeployment.sol`:
  - Add `_deploySlippageCoverageVault()` (upgradeable transparent proxy).
  - Update `_deploySwapper()` to take new `(allocator, slippageVault)` args.
  - CREATE3 prediction breaks the circular dep at deploy time (Vault constructor takes the predicted Swapper address; Swapper constructor takes the predicted Vault address).
  - Register both in `_deployContracts()`.
- [ ] `script/base/AccessManagerBaseSetup.sol`:
  - `_setupTarget__SlippageCoverageVault(deployer)`.
  - Register in `_setup_Targets`.
  - Rebalancer profile grants for `topUp`.
- [ ] `script/base/RolesConfig.sol`:
  - One `getRole__<setter>()` per restricted entrypoint:
    - `setOverrideMode` — OPERATIONAL_GUARDIAN, NO_DELAY, non-critical
    - `raisePullCapPerTx` — ADMIN_GUARDIAN, HIGH_DELAY, critical
    - `lowerPullCapPerTx` — OPERATIONAL_GUARDIAN, NO_DELAY, non-critical
    - `raiseWindowCap` — ADMIN_GUARDIAN, HIGH_DELAY, critical
    - `lowerWindowCap` — OPERATIONAL_GUARDIAN, NO_DELAY, non-critical
    - `setMaxSlippageBps` — ADMIN_GUARDIAN, HIGH_DELAY, critical
    - `setOverrideMaxSlippageBps` — ADMIN_GUARDIAN, HIGH_DELAY, critical
    - `topUp` — OPERATIONAL_GUARDIAN, NO_DELAY, non-critical
    - `sweep` — ADMIN_GUARDIAN, HIGH_DELAY, critical
  - Append entries to `getAllFunctionBasedRoles()` (bump array length).

Success criteria: deployment scripts compile and dry-run succeeds; AccessManager wiring matches the role table above.

#### Phase 4: PR / handoff

- [ ] PR title: `feat(SlippageCoverageVault): isolate slippage coverage from OwnedMulticall (VA-96)`.
- [ ] PR body: link Stermi I-06/I-14, Certora M-01, Recon-Fuzz #22, Recon-Fuzz #33 with disposition. Include role wiring delta. Note: Swapper redeploys; existing AccessManager grants pointed at old Swapper become invalid; deployment ticket re-wires.
- [ ] Comment back on Recon-Fuzz #22 and #33 referencing the merged PR.
- [ ] Update VA-96 Linear status to In Review on PR open.

## Alternative Approaches Considered

| Approach | Why rejected |
|---|---|
| Allocator-side `isWhitelistedSwapper` mapping (v2 from Linear changelog) | Redundant under push-based vault. Vault's immutable `SLIPPAGE_RECIPIENT` already gates this — adding a whitelist on top reverts the same path earlier with no security gain. |
| Allocator-side `isWhitelistedCoverageSource` mapping (v1 from Linear changelog) | Parameter (`slippageCoverageSource`) no longer exists in the push-based model. |
| Approval-based vault (`approvePull` setting `IERC20.approve`) | Keeps the stale-approval surface. Push-based eliminates the entire approval surface. |
| Token-bucket sliding window (CCIP `RateLimiter` shape) | Recommended by best-practices research. Better boundary semantics (no 2x-burst at rollover). Deferred to v2 for now to keep the surface area minimal — fixed-window is sufficient under treasury-comfort sizing. Risks table flags the boundary-burst concern. |
| Constants for slippage bounds (v3 baseline) | Overridden during interview to "governance-tunable storage" so post-launch tuning doesn't require a Swapper redeploy + AccessManager re-wire. |
| Auto-expiry TTL on override mode | Adds storage + comparison logic for marginal safety. Manual revert by guardian is the simpler, audit-friendly choice; precedented by MakerDAO `DssEmergencySpells`. |

## Acceptance Criteria

### Functional Requirements

#### Vault contract (`SlippageCoverageVault`)
- [ ] New contract at `src/periphery/SlippageCoverageVault.sol` inheriting `Initializable`, `AccessManagedUpgradeable`, `ReentrancyGuardTransientUpgradeable`, `ISlippageCoverageVault`.
- [ ] Immutable `SLIPPAGE_RECIPIENT` set at construction; `address(0)` reverts with `Errors.ZeroAddress()`.
- [ ] `pullCoverage(address asset, uint256 amount)` callable only by `SLIPPAGE_RECIPIENT` (revert: `OnlyRecipient`); `amount == 0` reverts with `Errors.ZeroAmount()`.
- [ ] In normal mode: enforce `amount <= pullCapPerTx[asset]` (revert: `ExceedsPerTxCap`).
- [ ] In normal mode: enforce sliding-window cap via `_consumeWindow` (revert: `ExceedsWindowCap`).
- [ ] In override mode: bypass per-tx and window caps; emit `CoveragePulled` with `overrideMode = true`.
- [ ] State updates (consume window) BEFORE `safeTransfer`.
- [ ] `nonReentrant` on `pullCoverage`, `topUp`, `sweep`.
- [ ] `setOverrideMode(bool)` — `OPERATIONAL_GUARDIAN`, NO_DELAY.
- [ ] `raisePullCapPerTx` / `lowerPullCapPerTx` — directional ACL by selector (raise = ADMIN+HIGH_DELAY+critical; lower = OPERATIONAL+NO_DELAY).
- [ ] `raiseWindowCap` / `lowerWindowCap` — same split. Reject `windowSeconds == 0`.
- [ ] `setMaxSlippageBps` / `setOverrideMaxSlippageBps` — ADMIN+HIGH_DELAY+critical.
- [ ] `topUp(asset, amount)` — `OPERATIONAL_GUARDIAN`, NO_DELAY. Pulls from caller via `safeTransferFrom`.
- [ ] `sweep(asset, amount, to)` — ADMIN+HIGH_DELAY+critical.
- [ ] No `IERC20.approve` ever called.
- [ ] Events: `CoveragePulled`, `OverrideModeSet`, `PullCapPerTxRaised`, `PullCapPerTxLowered`, `WindowCapRaised`, `WindowCapLowered`, `MaxSlippageBpsSet`, `OverrideMaxSlippageBpsSet`, `ToppedUp`, `Swept`.
- [ ] All custom errors carry `@custom:selector 0x________` natspec.

#### Swapper hardenings
- [ ] `SLIPPAGE_VAULT` immutable; constructor reverts on `address(0)`.
- [ ] `SlippageParams` moved to `ISwapper.sol`; `slippageCoverageSource` removed.
- [ ] `targets.length == callDatas.length` check.
- [ ] Hardening 1: `targets[i] != SLIPPAGE_VAULT` for every i (revert: `BadTarget`).
- [ ] Hardening 2: `slippageBps <= maxBps` where `maxBps` toggles by `vault.getOverrideMode()` (revert: `SlippageToleranceTooHigh`).
- [ ] Hardening 3: `IERC20(assetIn).balanceOf(address(this)) == 0` after target loop (revert: `AssetInLeftOver`).
- [ ] Coverage pulled via `ISlippageCoverageVault(SLIPPAGE_VAULT).pullCoverage(assetOut, slippageAmount)`.
- [ ] `SlippageCovered` event continues to be emitted with the vault as the indexed source.

#### Allocator
- [ ] No code changes. PR body documents that the existing `amountOut >= expectedAmountOut` invariant is preserved.

### Non-Functional Requirements
- [ ] No new gas regressions on the happy-path swap > +2k gas.
- [ ] All custom errors carry the project's `@custom:selector` natspec convention.
- [ ] All events follow `Param indexed` patterns from `WithdrawalPolicy.sol`.
- [ ] `forge build --deny warnings` passes.
- [ ] `forge test` passes, no new SECCO findings on `slither`/`solhint`.

### Quality Gates
- [ ] All new functions have NatSpec.
- [ ] All four attack paths (A/B/C/D) have explicit test coverage.
- [ ] PR review by at least one engineer + Alpay (audit liaison).

## Success Metrics

- All four Recon paths (A/B/C/D) covered by named adversarial tests in PR.
- Stermi I-06, I-14, Certora M-01, Recon-Fuzz #22, Recon-Fuzz #33 closed via PR cross-references.
- Audit re-review confirms no new findings against the vault's surface.

## Dependencies & Prerequisites

- Allocator deployed (existing).
- AccessManager deployed and operationally configured (existing).
- Treasury process for funding the vault post-deploy (deployment-ticket scope).
- Swapper redeploy invalidates existing AccessManager grants pointed at the old Swapper — deployment ticket re-wires.

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Boundary 2x-burst at fixed-window rollover | Medium | Low (capped at `windowCap`, treasury-bounded) | Document explicitly. v2 follow-up: switch to token-bucket if operational data shows abuse. |
| FoT / rebasing token registered post-launch | Low | Medium (cap counts gross, recipient gets net) | Asset-registry governance gating; explicitly document that vault assumes non-FoT, non-rebasing assets. |
| Window-cap clock-skew griefing | Low | Low | Window sized for treasury comfort, not minute-level precision. |
| Governance setter delay misconfigured | Medium | High | Directional split is by selector name, not value; AccessManager wiring tested in dry-run; deployment ticket reviewer checklist explicitly lists role table. |
| Swapper redeploy invalidates existing AccessManager grants | High (expected) | Medium (operational) | PR body lists wiring delta; deployment ticket re-wires; tests verify new grants. |
| `topUp` race with `pullCoverage` causing temporary depletion | Medium | Low | `pullCoverage` reverts on insufficient balance; manager retries after `topUp`. Off-chain monitor watches vault balance. |
| Slippage bound setter compromised (admin lifts MAX to 50% in normal mode) | Low | Medium | Critical role + HIGH_DELAY on raises. Window cap still bounds total drain. |
| `pullCapPerTx == 0` for a configured asset blocking emergency rebalance | Medium (operational) | Medium | Override mode bypasses per-tx and window caps. Documented runbook. |
| Override mode armed and forgotten | Low | High | Off-chain monitor alerts on `OverrideModeSet(true)` events; deployment runbook requires unwind. Manual revert chosen over TTL precisely so the operator stays accountable. |

## Future Considerations

- Token-bucket sliding window (v2): switch the `Window` struct + `_consumeWindow` to the CCIP `RateLimiter` shape. No interface change required.
- Per-asset slippage bounds: today the bounds are global. If audit shows that different assets need different tolerance ceilings (e.g., USDC ≤ 0.5%, GHO ≤ 1%), promote `maxSlippageBps` from scalar to `mapping(address asset => uint16)`.
- Override TTL: add `overrideExpiry` if operational data shows guardians forgetting to unwind. Spec design today is intentionally TTL-free.
- Multi-recipient: not in scope. If multiple Swappers ever need coverage, deploy multiple vaults — the immutable binding model is the security floor.

## Documentation Plan

- Update `README.md` periphery section with `SlippageCoverageVault` entry.
- Update audit-finding tracker with disposition of Stermi I-06/I-14, Certora M-01, Recon-Fuzz #22 + #33.
- Deployment runbook entry: post-deploy steps to fund the vault, set per-asset caps, set initial slippage bounds.

## References & Research

### Internal References
- Linear: VA-96 (https://linear.app/aavelabs/issue/VA-96).
- Notion analysis: https://www.notion.so/aave/Jo-o-s-analysis-Swapper-SlippageCoverageSource-3569d63a22de80f5b297d3e947803303
- Repo files:
  - `src/periphery/Swapper.sol` (current implementation)
  - `src/periphery/OwnedMulticall.sol` (drain paths A/D)
  - `src/core/Allocator.sol:404-427` (1:1 invariant; do not touch)
  - `src/periphery/WithdrawalPolicy.sol` (closest analog: AccessManaged + ERC-7201 + restricted setters)
  - `src/types/Errors.sol` (shared error library + selector NatSpec convention)
  - `script/base/RolesConfig.sol`, `AccessManagerBaseSetup.sol`, `Create3AddressBook.sol`, `EarningChainDeployment.sol`
- Research files:
  - `research/repo-analysis.md`
  - `research/best-practices.md`
  - `research/framework-docs.md`
  - `research/specflow-analysis.md`

### External References
- Recon-Fuzz #22: https://github.com/Recon-Fuzz/aave-review/issues/22
- Recon-Fuzz #33: https://github.com/Recon-Fuzz/aave-review/issues/33#issuecomment-4377337057
- EIP-7201: https://eips.ethereum.org/EIPS/eip-7201
- OpenZeppelin AccessManager v5: https://docs.openzeppelin.com/contracts/5.x/access-control
- Chainlink CCIP RateLimiter: https://github.com/code-423n4/2024-11-chainlink/blob/main/contracts/src/ccip/libraries/RateLimiter.sol
- MakerDAO DssEmergencySpells: https://github.com/sky-ecosystem/dss-emergency-spells
- Trail of Bits invariants: https://blog.trailofbits.com/2025/02/12/the-call-for-invariant-driven-development/

### Related Work
- PR #270 (constants), PR #274 (gasLimit hoist), PR #275 (BridgeParams → AdapterData) — recent merged work establishing the Swapper-redeploy precedent and the AccessManager wiring patterns.
- Stermi I-06, I-14 (audit reports).
- Certora M-01 (audit report — capital-isolation portion only; sizing is treasury's lane).
- João J-06 (partially trusted roles need bounded blast radius).

## Test Plan

### Unit (vault)
Naming convention: `test_<fn>_reverts_<cond>` and `test_<fn>_<positiveOutcome>` per repo convention.

- [ ] `test_constructor_reverts_ifRecipientIsZero` — Path A/D structural defense.
- [ ] `test_initialize_setsBoundsAndAuthority` — happy path.
- [ ] `test_pullCoverage_reverts_ifCallerIsNotRecipient` — Path B (malicious swapper).
- [ ] `test_pullCoverage_reverts_ifAmountIsZero`.
- [ ] `test_pullCoverage_reverts_ifAmountExceedsPerTxCap` — Path C (manipulated params bounded).
- [ ] `test_pullCoverage_reverts_ifAmountExceedsWindowCap` — sustained compromise bounded.
- [ ] `test_pullCoverage_reverts_ifWindowUnconfigured`.
- [ ] `test_pullCoverage_consumesWindowAndUpdatesState`.
- [ ] `test_pullCoverage_firstCallRollsOverFromZero` — default-state edge.
- [ ] `test_pullCoverage_rollsOverAtBoundary` — `vm.warp` past `windowSeconds`.
- [ ] `test_pullCoverage_overrideModeBypassesPerTxCap`.
- [ ] `test_pullCoverage_overrideModeBypassesWindowCap`.
- [ ] `test_pullCoverage_emitsCoveragePulledWithOverrideFlag`.
- [ ] `test_setOverrideMode_reverts_ifNotAuthorized` — role enforcement.
- [ ] `test_setOverrideMode_flipBetweenPulls_secondPullRespectsCaps`.
- [ ] `test_raisePullCapPerTx_reverts_ifNotIncreasing`.
- [ ] `test_lowerPullCapPerTx_reverts_ifNotDecreasing`.
- [ ] `test_raisePullCapPerTx_requiresAdminWithDelay` (via MockAccessManager).
- [ ] `test_lowerPullCapPerTx_requiresOperationalNoDelay`.
- [ ] `test_raiseWindowCap_reverts_ifWindowSecondsZero`.
- [ ] `test_lowerWindowCap_reverts_ifWindowSecondsZero`.
- [ ] `test_setMaxSlippageBps_emitsEvent`.
- [ ] `test_topUp_pullsFromCallerAndEmits`.
- [ ] `test_topUp_reverts_ifAmountZero`.
- [ ] `test_topUp_reverts_ifNotAuthorized`.
- [ ] `test_sweep_pushesToRecipientAndEmits`.
- [ ] `test_sweep_reverts_ifZeroAddress`.
- [ ] `test_sweep_reverts_ifNotAuthorized`.

### Unit (Swapper hardenings)
- [ ] `test_constructor_reverts_ifSlippageVaultIsZero`.
- [ ] `test_executeSwap_reverts_ifTargetIsVault` — Path C-4.
- [ ] `test_executeSwap_reverts_ifSlippageToleranceAboveMax_normalMode` — Path C-2.
- [ ] `test_executeSwap_reverts_ifSlippageToleranceAboveMax_overrideMode` — bound at OVERRIDE_MAX.
- [ ] `test_executeSwap_reverts_ifAssetInLeftover` — Path C-3.
- [ ] `test_executeSwap_reverts_ifTargetsAndCallDatasLengthMismatch`.
- [ ] `test_executeSwap_pullsCoverageOnShortfall` — happy path.
- [ ] `test_executeSwap_pullsCoverageInOverrideMode_largeSlippage` — emergency happy path.
- [ ] `test_executeSwap_doesNotPullCoverage_whenAmountOutMeetsExpectation`.
- [ ] `test_executeSwap_emitsSlippageCoveredWithVaultAsSource`.
- [ ] Existing tests updated for new constructor and removed `slippageCoverageSource`.

### Integration
- [ ] Update `test/unit/periphery/OwnedMulticall.t.sol::test_rebalance_viaOwnedMulticall_swapWithSlippageCoverage` — manager's `aggregate3` no longer pre-approves Swapper; coverage flows from vault.
- [ ] `test_rebalance_viaOwnedMulticall_attemptDirectVaultCallReverts` — Path A regression: manager craft `aggregate3([vault.pullCoverage(...)])` → reverts (OnlyRecipient).

### Out of scope (per Decision #7)
- Echidna / Medusa invariant suite. Best-practices research suggests the following invariants if added later:
  - `invariant_vaultBalanceMonotonicExceptPullAndSweep`
  - `invariant_consumedNeverExceedsCap`
  - `invariant_overrideModeImpliesGuardianCalled`
  - `invariant_noApproveCalled`
  - `invariant_recipientNeverChanges`
