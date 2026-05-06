# Remove Default Strategy — Technical Specification

## Overview

Remove the per-asset "default strategy" concept from `Allocator`. Drop `getDefaultStrategy`, `setDefaultStrategy`, `DefaultStrategySet` event, `DefaultStrategy` error, the `defaultStrategyByAsset` storage mapping, and all dependent flows (auto-deposit on user deposit / bridge callback; default-first preference on withdrawal; auto-clear on `distrustStrategy`). Replace `Allocator.deposit` and `Allocator.depositAllowIdle` with a single `pullIdle(asset, amount)` that pulls from the TransferHelper and emits `AssetLeftIdle`.

Pre-launch ABI break, expected. Roughly 18 files touched, ~150 lines deleted, ~30 added.

## Problem Statement

Default strategy is the only deposit path that runs without a manager-driven rebalance, which makes it the only permissionlessly-triggerable strategy interaction. That makes it a recurring source of low/info audit findings (slippage round-trips during deposit, auto-clear semantics on `distrustStrategy`, edge cases on auto-deposit reentrancy, etc.). Operationally, the team plans to deploy with default strategy set to `address(0)` for every asset, so the feature provides zero value at runtime while still expanding the audit/test surface.

Slack alignment (Alan, Victor, Joao) — see `interview-notes.md` for context.

## Proposed Solution

Three coordinated cuts:

1. **Drop the storage and the surface**. Delete `defaultStrategyByAsset`, both setter and getter, the event/error, and the auto-clear branch on `distrustStrategy`.
2. **Collapse deposit to a single push helper**. Replace `deposit` and `depositAllowIdle` with `pullIdle(asset, amount)`. Funds always land idle. Manager rebalances them later. Treasury covers user APY in the gap (already the operational stance).
3. **Linearize withdrawal**. Drop the default-first try/catch block in `withdraw`. Iterate `assetStrategies` from index 0 in a single loop.

ACL surface shrinks: one fewer function-based role (`setDefaultStrategy`) across `RolesConfig`, `AccessManagerBaseSetup`, and the AccessManager wiring tests.

## Technical Approach

### Architecture

```
Before                                After
────────────────────────────────      ────────────────────────────────
deposit(asset, amount)                pullIdle(asset, amount)
  ├─ if defaultStrategy[asset] != 0     ├─ if amount == 0: return
  │   └─ depositToStrategy(default)     ├─ require asset allowed
  │       (slippage path inside)        ├─ pull via TransferHelper
  └─ else: emit AssetLeftIdle           └─ emit AssetLeftIdle

depositAllowIdle(asset, amount)       (folded into pullIdle)
  ├─ try depositToStrategy(default)
  └─ catch: emit AssetLeftIdle

withdraw(asset, amount)               withdraw(asset, amount)
  ├─ idle first                         ├─ idle first
  ├─ default strategy first              └─ iterate assetStrategies
  │   (try/catch)                            in insertion order
  └─ iterate assetStrategies                 (try/catch each)
      (skip default)
```

The Allocator becomes purely manager-driven for strategy interactions. The only permissionless writes remaining are: idle pulls (system-only via `onlyDepositor`) and the `withdraw` outflow (`onlyWithdrawer`).

### Implementation phases

#### Phase 1: Allocator + interface

Drop the default-strategy surface from `src/core/Allocator.sol` and `src/interfaces/IAllocator.sol`:

- `AllocatorStorage` — remove `defaultStrategyByAsset`. Pre-launch storage layout shift documented in PR body.
- Remove `getDefaultStrategy`, `setDefaultStrategy`, `_setDefaultStrategy`.
- Remove `DefaultStrategySet` event and `DefaultStrategy(address)` error.
- `_removeStrategy` (line 596): drop the `DefaultStrategy(strategy)` revert clause.
- `distrustStrategy` (lines 361-363): drop the auto-clear-default branch.
- `withdraw` (lines 230-252): delete the default-first try/catch block and the `if (strategy != defaultStrategy)` guard inside the post-loop. Single flat iteration in insertion order.
- Replace `deposit` and `depositAllowIdle` with `pullIdle`:

```solidity
/// @inheritdoc IAllocator
function pullIdle(address asset, uint256 amount) external override onlyDepositor nonReentrant {
    if (amount == 0) {
        return;
    }
    require(IAssetRegistry(ASSET_REGISTRY).isDepositToAllocatorAllowed(asset), Errors.UnsupportedAsset(asset));
    ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
    emit AssetLeftIdle(asset, amount);
}
```

Update interface `src/interfaces/IAllocator.sol` to match: drop event, error, getter, setter; replace `deposit`/`depositAllowIdle` declarations with `pullIdle`; update `withdraw` and `distrustStrategy` natspec.

Acceptance: `forge build --deny warnings` clean for `src/`.

#### Phase 2: Callers

Update three call sites:

- `src/core/accounting/FundsHandler.sol::processDeposit` (line 122):
  - Old: `return IAllocator(ALLOCATOR).deposit(asset, amount);`
  - New: `IAllocator(ALLOCATOR).pullIdle(asset, amount); return amount;`
- `src/core/accounting/FundsHandler.sol::fundsArrivedFromChainCallback` (line 172):
  - Old: `IAllocator(ALLOCATOR).depositAllowIdle(asset, amount);`
  - New: `IAllocator(ALLOCATOR).pullIdle(asset, amount);`
- `src/core/earning/EarningChainGateway.sol` (line 156):
  - Same `depositAllowIdle` → `pullIdle` swap.

`processDeposit returns (uint256)` ABI stays stable; always returns input amount. `StableVault.deposit` and downstream principal accounting unchanged.

#### Phase 3: Deployment + ACL

- `script/base/RolesConfig.sol`:
  - Delete `getRole__setDefaultStrategy()` (lines 435-444).
  - Drop the array entry at line 658 (currently roles[29]).
  - Renumber subsequent indices and decrement the `new Role[](N)` literal.
- `script/base/AccessManagerBaseSetup.sol`:
  - `_setupProfile__Rebalancer` (line 269): drop entry, length 6 → 5, renumber.
  - `_setupProfile__Disabler` (line 299): drop entry, length 14 → 13, renumber.
  - `_setupTarget__Allocator` (line 343): drop entry, length 9 → 8, renumber.
- `script/base/AccountingChainDeployment.sol::_setupAllocator`: delete the three `setDefaultStrategy` calls (lines 219, 224, 229).
- `script/base/EarningChainDeployment.sol::_setupAllocator`: delete the two `setDefaultStrategy` calls (lines 174, 179).

Acceptance: AccessManager dry-run passes; no orphaned selectors.

#### Phase 4: Tests

Per the inventory in `research/repo-analysis.md`:

**`test/BaseTest.t.sol`**:
- Drop the four `setDefaultStrategy` setup calls (lines 821, 822, 827, 828).
- OPERATOR_ROLE selector arrays at lines 923, 1005: drop `setDefaultStrategy.selector` entry, length 2 → 1 (`rebalance` only).
- Add helper `_routeIdleToStrategy(allocator, asset, strategy, amount)` that wraps a single `RebalanceParams` allocation step. Reduces e2e diff size.

**`test/unit/core/Allocator.t.sol`** (~50 references):
- Drop tests covering `setDefaultStrategy` semantics (8 tests).
- Drop tests covering `getDefaultStrategy` (4 tests).
- Drop tests asserting auto-deposit slippage path (8 tests — `test_deposit_*Slippage*`, `test_deposit_revert_ifSharesMintedIsZero`, etc.).
- Rewrite deposit tests as "always idle" via `pullIdle` (3 tests).
- Rewrite withdrawal tests, dropping default-first preference (8 tests). Reorder seeded amounts to match `assetStrategies` insertion order.
- Drop `test_disableDepositsToStrategy_withMultiCall` (uses `setDefaultStrategy.selector` in the multicall payload).
- Rewrite `test_disableDepositsToStrategy_preventsDepositsToStrategy` and `test_enableDepositsToStrategy_enablesDepositsToStrategy` to assert toggle-blocks-rebalance-allocation rather than toggle-blocks-deposit.
- Drop `_depositToReentrantStrategy` helper and the two reentrancy tests on `deposit`/`depositAllowIdle` (auto-deposit gone → no reentrancy via strategy callback).

**`test/unit/core/accounting/FundsHandler.t.sol`**:
- `test_processDeposit_pushesFundsToAllocatorWithSlippage` (line 159): drop. Slippage path no longer reachable.
- Other `processDeposit` tests pass unchanged with `netDepositAmount == amount`.

**`test/unit/access/AccessManagerSetupBaseTest.sol`**:
- Drop expected entries at lines 199, 224 (Rebalancer / Disabler profiles).
- Drop assertion at line 408 (Allocator target setup).
- Drop assertion at line 532 (disabler can-call).
- Update array sizes to match.

**`test/unit/access/fork/AccessManager{Earning,Accounting}ChainSetup.Fork.t.sol`**:
- Replace `allocator.getDefaultStrategy(asset)` lookups with `allocator.getStrategiesForAsset(asset)[0]` or pin deployed addresses.

**`test/unit/periphery/OwnedMulticall.t.sol`**:
- Drop setup `setDefaultStrategy` calls (lines 127-129).
- Replace `getDefaultStrategy` reads in `_buildEntireFlowRebalanceParams` with explicit handles (`_defaultUsdtStrategy`, `_defaultGhoStrategy`).

**`test/e2e/*.t.sol`** (6 files):
- Drop `getDefaultStrategy` lookups; assert idle balance lands on Allocator after `deposit`.
- Insert explicit `RebalanceParams` allocation step (via the new `_routeIdleToStrategy` helper) before any post-rebalance balance assertions.

**`test/mocks/MockAllocator.sol`**:
- Drop `getDefaultStrategy`, `deposit` (replace with `pullIdle`), `depositAllowIdle`, `setDefaultStrategy` stubs.
- Drop `mockAmountOfSlippage` machinery (no longer reachable).

**`test/mocks/MockFundsHandler.sol`**:
- Update if it mirrors any of the dropped surface (line 52).

Acceptance: `forge test` passes (target ≥ existing pass count modulo deletions).

#### Phase 5: PR / handoff

- PR body: "VA-157: remove default strategy. Pre-launch ABI break. Storage layout shift in `AllocatorStorage` (acceptable since not yet deployed). Closes audit findings tied to default strategy."
- Update VA-157 status to In Review.
- Comment on the Slack thread with the merged PR link.

## Alternative Approaches Considered

| Approach | Why rejected |
|---|---|
| Keep `setDefaultStrategy` selector, no-op the body (deprecate-not-delete) | Audit-noisy, leaves ABI surface for no operational value |
| Keep auto-deposit, drop only the setter (default forever address(0)) | Doesn't simplify the Allocator at all; the auto-deposit branch becomes dead code that auditors still review |
| Add explicit per-asset withdrawal-priority list as a successor feature | Reintroduces a privileged setter, partly defeats the simplification. Not needed for v1; insertion order is sufficient. |

## Acceptance Criteria

### Functional
- [ ] `Allocator` exposes neither `setDefaultStrategy`, `getDefaultStrategy`, nor `defaultStrategyByAsset` (any of the three would be dead surface).
- [ ] `IAllocator` does not declare `DefaultStrategySet` event nor `DefaultStrategy` error.
- [ ] `Allocator.deposit` and `Allocator.depositAllowIdle` are removed; `Allocator.pullIdle(address,uint256)` is the only deposit-side entrypoint.
- [ ] `pullIdle` semantics:
  - [ ] `onlyDepositor nonReentrant` modifiers.
  - [ ] Zero amount is a no-op (no event, no revert).
  - [ ] Reverts on unsupported asset (`Errors.UnsupportedAsset`).
  - [ ] Pulls via `TransferHelper.pull`.
  - [ ] Emits `AssetLeftIdle(asset, amount)`.
- [ ] `Allocator.withdraw`:
  - [ ] No default-first try/catch block.
  - [ ] Iterates `assetStrategies` from index 0 with try/catch on each.
  - [ ] Emits `StrategyWithdrawalFailed(strategy, asset, amountRemaining)` on per-strategy failure.
  - [ ] Reverts `Errors.InsufficientFunds()` if `amountRemaining > 0` after the loop.
- [ ] `Allocator.distrustStrategy` does not auto-clear default (no such concept).
- [ ] `Allocator._removeStrategy` does not emit `DefaultStrategy(strategy)` revert.
- [ ] `FundsHandler.processDeposit` returns input `amount` unchanged.
- [ ] `FundsHandler.fundsArrivedFromChainCallback` calls `pullIdle`.
- [ ] `EarningChainGateway` callback calls `pullIdle`.
- [ ] AccessManager wiring: `setDefaultStrategy` selector no longer present in any profile or target setup.

### Non-Functional
- [ ] `forge build --deny warnings` clean.
- [ ] `forge test` 0 failures.
- [ ] No regression in test count after re-purposing tests (drops are documented in PR body).
- [ ] No new compiler warnings.

### Quality Gates
- [ ] PR body explicitly calls out:
  - Storage layout shift in `AllocatorStorage` (pre-launch acceptable).
  - ABI break: `deposit`, `depositAllowIdle`, `setDefaultStrategy`, `getDefaultStrategy` selectors removed; `pullIdle` selector added.
  - AccessManager role table changes: one fewer function-based role.
  - Audit findings tied to default-strategy that this PR closes (link Linear / Slack thread).

## Success Metrics

- Allocator code shrinks by ~80 lines net (deletions − additions).
- AccessManager array surface area shrinks by 3 entries (Rebalancer, Disabler, Allocator target).
- ~10 audit-finding categories tied to default strategy become moot.
- Test surface shrinks by ~25 tests (drops) net of ~10 rewrites.

## Dependencies & Prerequisites

- None. Changes are self-contained within `src/core/Allocator.sol` + interface + 2 caller files + script wiring + test files.

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Interest accrual gap on idle deposits | High | Low (already accepted) | Manager rebalance cadence; treasury covers user APY in the gap |
| Withdrawal ordering surprise (no default-first preference) | Low | Low | Iteration order is `EnumerableSet` insertion order; tests pin behavior; manager controls add-order |
| External integrator depending on `getDefaultStrategy` view | Low (pre-launch) | Low | Pre-launch ABI break, expected. Document in PR body. |
| Storage layout shift breaks pre-launch testnet state | Medium (any vnet with state) | Medium | Document in PR body; advise fresh deploy on any testnet that has state. |
| Re-add cost if we ever want default back | Low | Medium | Acceptable. The feature is a contained mapping + helpers; re-adding is similarly-sized. |
| Test rewrite introduces seeding-order bugs | Medium | Low | New `_routeIdleToStrategy` helper centralizes the rebalance-routing pattern; reduces per-test divergence. |

## Future Considerations

- If a per-asset withdrawal-priority list ever becomes operationally needed, it can be added as a separate feature later (new mapping + setter + iteration change). v1 stays minimal.
- A future "auto-rebalance keeper" could close the idle-deposit gap if treasury exposure becomes meaningful — but that's a different problem space (keeper infra) and out of scope here.

## References & Research

### Internal References
- `src/core/Allocator.sol` — main change site.
- `src/interfaces/IAllocator.sol` — surface change.
- `src/core/accounting/FundsHandler.sol:122, 172` — call sites.
- `src/core/earning/EarningChainGateway.sol:156` — call site.
- `script/base/RolesConfig.sol:435-444, :658` — ACL drops.
- `script/base/AccessManagerBaseSetup.sol:269, 299, 343` — profile/target drops.
- Research file: `research/repo-analysis.md`.

### Related Work
- VA-157 (Linear): https://linear.app/aavelabs/issue/VA-157
- Slack thread (Alan, Victor, Joao alignment): https://aavelabs.slack.com/archives/C09C7L5AGHW/p1778078357145069
- Audit findings tied to default strategy: tracked in audit response doc (out of repo).

## Test Plan

### Unit
- `Allocator.t.sol` — drop ~25 tests, rewrite ~10. New tests:
  - `test_pullIdle_pullsFromTransferHelperAndEmitsIdle` (replaces deposit happy paths).
  - `test_pullIdle_doesNotRevert_ifAmountIsZero`.
  - `test_pullIdle_reverts_ifNonDepositorCalls`.
  - `test_pullIdle_reverts_ifAssetRegistryDoesNotAllowDepositIntoAllocator`.
  - `test_withdraw_iteratesAssetStrategiesInInsertionOrder` (new explicit assertion).
- `FundsHandler.t.sol` — drop slippage test.
- Confirm `processDeposit` return-value behavior is `== amount` always.

### Integration
- `OwnedMulticall.t.sol` — rebalance flows updated to pass strategies explicitly (not via `getDefaultStrategy`).

### E2E
- Six e2e tests updated to use `_routeIdleToStrategy` helper between deposit and post-rebalance assertions.

### AccessManager
- Setup tests updated for one fewer function-based role across Rebalancer, Disabler, and Allocator target.
- Fork tests updated to find strategies via `getStrategiesForAsset(asset)[0]` instead of `getDefaultStrategy`.
