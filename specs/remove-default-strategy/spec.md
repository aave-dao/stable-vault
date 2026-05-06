# Remove Default Strategy Spec

## Metadata
- Project: stable-vault
- Milestone: 2. Certora/GetRecon & Final Contract changes
- Linear Issue: VA-157
- Interview Date: 2026-05-06
- Status: [x] Draft / [ ] Ready for Review / [ ] Approved

## Summary

Remove the per-asset default-strategy concept from `Allocator`. Drop the storage mapping, the setter/getter, the event/error, and the dependent flows (auto-deposit on user deposit / bridge callback; default-first preference on withdrawal; auto-clear on `distrustStrategy`). Replace `Allocator.deposit` and `Allocator.depositAllowIdle` with a single `pullIdle(asset, amount)`. Manager-driven rebalance is now the only path that moves funds into a strategy.

Operationally aligned: deployment plans set default to `address(0)` for every asset, so the feature ran 0% in production while expanding the audit/test surface. Pre-launch ABI break, expected.

## Requirements

### Functional
1. `Allocator` no longer exposes `setDefaultStrategy`, `getDefaultStrategy`, or the underlying `defaultStrategyByAsset` mapping.
2. `IAllocator` no longer declares `DefaultStrategySet` event or `DefaultStrategy` error.
3. `Allocator.pullIdle(address asset, uint256 amount)` is the single deposit-side entrypoint. Modifiers: `onlyDepositor nonReentrant`. Zero amount = no-op (bridge-callback safety). Reverts on unsupported asset. Pulls via `TransferHelper.pull`. Emits `AssetLeftIdle(asset, amount)`.
4. `Allocator.withdraw` iterates `assetStrategies` from index 0 in insertion order — no default-first preference.
5. `Allocator.distrustStrategy` does not auto-clear default (concept gone).
6. `Allocator._removeStrategy` does not throw `DefaultStrategy(...)` (revert clause removed).
7. `FundsHandler.processDeposit` keeps `returns (uint256)`; returns input `amount` unchanged.
8. `FundsHandler.fundsArrivedFromChainCallback` and `EarningChainGateway` callback both call `pullIdle`.
9. AccessManager: `setDefaultStrategy` selector dropped from RolesConfig, Rebalancer profile, Disabler profile, and Allocator target setup.

### Non-Functional
- `forge build --deny warnings` clean.
- `forge test` 0 failures.
- No regression in pass count beyond documented test drops.

## Technical Design

### Architecture

```
Before                                 After
────────────────────────────────       ────────────────────────────────
deposit(asset, amount)                 pullIdle(asset, amount)
  ├─ default exists → auto-deposit       ├─ amount == 0 → return
  └─ else → idle                         ├─ require asset allowed
                                         ├─ pull via TransferHelper
depositAllowIdle(asset, amount)          └─ emit AssetLeftIdle
  ├─ try auto-deposit
  └─ catch → idle

withdraw(asset, amount)                withdraw(asset, amount)
  ├─ idle first                          ├─ idle first
  ├─ default first (try/catch)           └─ iterate assetStrategies
  └─ iterate (skip default)                  in insertion order
```

### Data Model

`AllocatorStorage` (`src/core/Allocator.sol:65-70`): drop `defaultStrategyByAsset`. Storage layout shifts; pre-launch acceptable.

### API Changes

**Removed (interface + impl):**
- `event DefaultStrategySet`
- `error DefaultStrategy(address)`
- `function getDefaultStrategy(address) view returns (address)`
- `function setDefaultStrategy(address,address) external`
- `function deposit(address,uint256) external returns (uint256)`
- `function depositAllowIdle(address,uint256) external`

**Added:**
- `function pullIdle(address,uint256) external` — `onlyDepositor nonReentrant`, zero-amount no-op, no return.

**Stable:**
- `FundsHandler.processDeposit returns (uint256)` (always returns input amount).
- `StableVault.deposit` external surface unchanged.

## Implementation Plan

### Phase 1: Allocator + interface
- [ ] `src/core/Allocator.sol`: drop default-strategy storage, getter, setter, event/error, auto-clear branch in `distrustStrategy`, `DefaultStrategy` revert in `_removeStrategy`. Linearize `withdraw` (drop default-first try/catch). Replace `deposit`/`depositAllowIdle` with `pullIdle`.
- [ ] `src/interfaces/IAllocator.sol`: same surface drops; add `pullIdle`; update `withdraw` and `distrustStrategy` natspec.

### Phase 2: Callers
- [ ] `src/core/accounting/FundsHandler.sol::processDeposit` (line 122) → `pullIdle`, return `amount`.
- [ ] `src/core/accounting/FundsHandler.sol::fundsArrivedFromChainCallback` (line 172) → `pullIdle`.
- [ ] `src/core/earning/EarningChainGateway.sol` (line 156) → `pullIdle`.

### Phase 3: Deployment + ACL
- [ ] `script/base/RolesConfig.sol`: drop `getRole__setDefaultStrategy()` + array entry; renumber + array length down by 1.
- [ ] `script/base/AccessManagerBaseSetup.sol`: drop entry from Rebalancer profile (length 6 → 5), Disabler profile (14 → 13), Allocator target (9 → 8). Renumber.
- [ ] `script/base/{Accounting,Earning}ChainDeployment.sol::_setupAllocator`: delete the `setDefaultStrategy` calls.

### Phase 4: Tests
- [ ] `test/BaseTest.t.sol`: drop the four `setDefaultStrategy` setup calls; OPERATOR selector arrays drop the entry. Add `_routeIdleToStrategy` helper.
- [ ] `test/unit/core/Allocator.t.sol`: drop ~25 tests (default-strategy semantics, slippage path, auto-clear, default-first withdrawal); rewrite ~10 (deposit-as-idle via `pullIdle`; insertion-order iteration). Drop `_depositToReentrantStrategy` helper + 2 reentrancy tests on auto-deposit.
- [ ] `test/unit/core/accounting/FundsHandler.t.sol`: drop `test_processDeposit_pushesFundsToAllocatorWithSlippage`.
- [ ] `test/unit/access/AccessManagerSetupBaseTest.sol`: drop entries at lines 199, 224, 408, 532; resize arrays.
- [ ] `test/unit/access/fork/AccessManager{Earning,Accounting}ChainSetup.Fork.t.sol`: replace `getDefaultStrategy` lookups.
- [ ] `test/unit/periphery/OwnedMulticall.t.sol`: drop setup `setDefaultStrategy`; replace `getDefaultStrategy` reads with explicit handles.
- [ ] `test/e2e/*.t.sol` (6 files): drop `getDefaultStrategy` lookups; assert idle-on-Allocator post-deposit; insert explicit rebalance step (via the new helper) before strategy-balance assertions.
- [ ] `test/mocks/MockAllocator.sol`: drop default-strategy stubs; add `pullIdle` stub; drop `mockAmountOfSlippage`.
- [ ] `test/mocks/MockFundsHandler.sol`: mirror the surface change if applicable.

### Phase 5: PR / handoff
- [ ] PR title: `feat: remove default strategy (VA-157)`.
- [ ] PR body lists ABI break, storage layout shift, AccessManager role-table delta, audit findings closed-by-this-PR.
- [ ] Comment on the Slack thread.
- [ ] Move VA-157 to In Review.

## Test Plan
- [ ] **Unit (Allocator)**: new tests `test_pullIdle_*` (happy path, zero-amount no-op, unauthorized caller, unsupported asset). Rewritten withdrawal tests assert insertion-order iteration. Drop default-strategy semantics tests.
- [ ] **Unit (FundsHandler)**: confirm `processDeposit` returns input amount unchanged; drop slippage test.
- [ ] **Unit (AccessManager)**: confirm one fewer function-based role across Rebalancer, Disabler, Allocator target.
- [ ] **Integration (OwnedMulticall)**: rebalance flows pass strategies explicitly.
- [ ] **E2E**: deposit lands idle on Allocator; explicit rebalance routes funds; balance assertions follow.

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Interest accrual gap on idle deposits | High | Low (already accepted) | Treasury covers user APY in the gap |
| Withdrawal ordering surprise (no default-first) | Low | Low | Insertion order is deterministic; tests pin behavior |
| External integrator depending on `getDefaultStrategy` | Low (pre-launch) | Low | Pre-launch ABI break, documented in PR body |
| Storage layout shift breaks pre-launch testnet state | Medium | Medium | PR body advises fresh deploy on any testnet with persisted state |
| Re-add cost if default ever needed back | Low | Medium | Acceptable; feature is a contained mapping + helpers |

## Open Questions (Resolved)

| Question | Answer | Decided By |
|---|---|---|
| Drop `deposit`/`depositAllowIdle` entirely or keep one with always-idle semantics? | **Drop both; replace with single `pullIdle`** | Joao, 2026-05-06 |
| Withdrawal iteration order without default-first | **Insertion order in `assetStrategies` set** | Joao, 2026-05-06 |
| ACL surface: drop `setDefaultStrategy` selector entirely or no-op? | **Drop entirely** | Joao, 2026-05-06 |
| `pullIdle` zero-amount behavior | **No-op** (bridge-callback safety) | spec, 2026-05-06 |
| `processDeposit` return-value ABI | **Stable** — always returns input amount | spec, 2026-05-06 |

## Interview Notes
See: [interview-notes.md](./interview-notes.md)

## Technical Details
See: [technical-spec.md](./technical-spec.md)

## Research
See: [research/](./research/)

---

## Approval
- [ ] Stakeholder Approved
- Approved date: ___

## Next Steps
After approval, run: `/dev:work specs/remove-default-strategy/technical-spec.md`
