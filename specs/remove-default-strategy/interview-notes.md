# Remove Default Strategy — Interview Notes

**Date:** 2026-05-06
**Driver:** João Martins
**Linear:** VA-157 — *Evaluate removal of default strategy due to risks*
**Branch (Linear):** `joao/va-157-evaluate-removal-of-default-strategy-due-to-risks`
**Slack thread:** https://aavelabs.slack.com/archives/C09C7L5AGHW/p1778078357145069

## Context

Default strategy is the only permissionlessly-triggerable deposit path on the Allocator (auto-deposit on user deposit / bridge callback). It's also the surface area for a steady stream of low/info audit findings. The team (Alan, Victor, Joao) agree: deployment plans set it to `address(0)` anyway, so the feature provides no value while expanding attack surface.

Slack alignment quotes:
- **Alan**: "If we will keep it to address(0) unused, then it's just better to remove it because it closes the surface of problems for a lot of low/info issues."
- **Victor**: "I would get rid of it long ago. The only reason I remember we didn't — is 'not change the code after audits' — which we already change a lot now."
- **João**: "Gonna do a PR to see how it looks like."

## Current surface

Default-strategy logic lives in:

| File | Sites |
|---|---|
| `src/core/Allocator.sol` | storage mapping, getter, deposit auto-flow, withdraw default-first preference, removeStrategy auto-clear, setDefaultStrategy, _setDefaultStrategy, _validateStrategyChange `DefaultStrategy` revert |
| `src/interfaces/IAllocator.sol` | `DefaultStrategySet` event, `DefaultStrategy` error, `getDefaultStrategy`, `setDefaultStrategy` |
| `script/base/RolesConfig.sol` | `getRole__setDefaultStrategy()`, array entry |
| `script/base/AccessManagerBaseSetup.sol` | `_setupTarget__Allocator` includes `setDefaultStrategy` |
| `script/base/{Accounting,Earning}ChainDeployment.sol` | `_setupAllocator` may call `setDefaultStrategy` |
| `test/BaseTest.t.sol` | calls `setDefaultStrategy` for GHO/USDC on both chains |
| `test/unit/core/Allocator.t.sol` | extensive coverage of default-strategy flows |
| `test/unit/access/AccessManagerSetupBaseTest.sol` | role assertions |
| `test/unit/periphery/OwnedMulticall.t.sol` | rebalance integration tests rely on default |
| `test/mocks/MockAllocator.sol` | mirror surface |

Total: ~150 references across 11 files.

## Scoping decisions (2026-05-06)

| # | Decision | Choice |
|---|---|---|
| 1 | Deposit behavior | **Drop `deposit` and `depositAllowIdle` entirely**; replace both with a single `pullIdle(asset, amount)` that pulls from TransferHelper and emits `AssetLeftIdle`. Callers (FundsHandler, EarningChainGateway) are updated. |
| 2 | Withdrawal iteration order | **Insertion order in the existing `assetStrategies` set.** No more default-first preference; just iterate the EnumerableSet from index 0. Smallest diff. |
| 3 | ACL/ABI surface | **Drop entirely.** Remove `setDefaultStrategy` from interface + impl + RolesConfig + AccessManagerBaseSetup + tests. Remove `DefaultStrategySet` event and `DefaultStrategy` error. Pre-launch ABI break, expected. |

## Acceptance criteria

### Allocator (`src/core/Allocator.sol`)
- [ ] Storage: drop `mapping(address asset => address strategy) defaultStrategyByAsset` from `AllocatorStorage`.
- [ ] Drop `getDefaultStrategy(address)` and `setDefaultStrategy(address,address)` from impl + interface.
- [ ] Drop `_setDefaultStrategy` internal helper.
- [ ] Drop `DefaultStrategySet` event and `DefaultStrategy` error.
- [ ] `_validateStrategyChange`: drop the `DefaultStrategy(strategy)` revert clause for the default-equals-strategy case (the case becomes impossible).
- [ ] `removeStrategy`: drop the auto-clear-default branch.
- [ ] **Replace** `deposit(address,uint256) returns (uint256)` and `depositAllowIdle(address,uint256)` with a single `pullIdle(address asset, uint256 amount)` external function that:
  - Requires `amount > 0` (or zero-no-op for callback parity — see decision below).
  - Requires `IAssetRegistry(...).isDepositToAllocatorAllowed(asset)`.
  - Pulls via `ITransferHelper(TRANSFER_HELPER).pull(asset, amount)`.
  - Emits `AssetLeftIdle(asset, amount)`.
  - Modifier set: `onlyDepositor nonReentrant`.
- [ ] `withdraw`: drop the default-first try/catch block; iterate `assetStrategies` from index 0 in a single loop. Skip-if-equal-default branch becomes a no-op.
- [ ] **Open question**: keep `depositAllowIdle` zero-amount no-op behavior (used by bridge callbacks) under the new `pullIdle`? Recommend: yes, treat zero amount as no-op (early return, no event) to preserve bridge-callback safety.

### Interface (`src/interfaces/IAllocator.sol`)
- [ ] Drop `event DefaultStrategySet`, `error DefaultStrategy`.
- [ ] Drop `getDefaultStrategy`, `setDefaultStrategy`.
- [ ] Drop `deposit`, `depositAllowIdle`. Add `pullIdle`.

### Callers
- [ ] `src/core/accounting/FundsHandler.sol::processDeposit` — replace `IAllocator.deposit(...) returns (uint256)` call with `IAllocator.pullIdle(...)`. Return `amount` directly to the caller (no per-strategy round-trip loss possible since no auto-deposit).
- [ ] `src/core/accounting/FundsHandler.sol::fundsArrivedFromChainCallback` — replace `depositAllowIdle` with `pullIdle`. Preserve the existing zero-amount no-op semantics for bridge safety.
- [ ] `src/core/earning/EarningChainGateway.sol` — same replacement.

### Deployment / ACL
- [ ] `script/base/RolesConfig.sol` — remove `getRole__setDefaultStrategy()` helper and array entry. Bump array length down by 1.
- [ ] `script/base/AccessManagerBaseSetup.sol::_setupTarget__Allocator` — drop `setDefaultStrategy` from selectors array. Add `pullIdle` if it should be permissioned… actually no, `pullIdle` uses `onlyDepositor` (the FundsHandler / Gateway), not AccessManager. Same wiring as today's `deposit` (no AccessManager role needed).
- [ ] `script/base/AccountingChainDeployment.sol::_setupAllocator` — drop any `setDefaultStrategy` call.
- [ ] `script/base/EarningChainDeployment.sol::_setupAllocator` — drop any `setDefaultStrategy` call.

### Tests
- [ ] `test/BaseTest.t.sol` — drop the four `setDefaultStrategy` calls (GHO+USDC × accounting+earning).
- [ ] `test/unit/core/Allocator.t.sol` — drop tests covering `setDefaultStrategy`, `getDefaultStrategy`, default-strategy auto-deposit, default-strategy auto-clear-on-removeStrategy, default-first withdrawal preference. Re-purpose deposit tests to assert always-idle behavior. Update withdrawal tests to assert insertion-order iteration.
- [ ] `test/unit/access/AccessManagerSetupBaseTest.sol` — drop `setDefaultStrategy` role assertion.
- [ ] `test/unit/periphery/OwnedMulticall.t.sol` — rebalance tests previously relied on default to receive deposited funds. Update them to explicitly route via `RebalanceParams` allocations.
- [ ] `test/mocks/MockAllocator.sol` — drop default-strategy surface; add `pullIdle`.

### Quality gates
- [ ] `forge build --deny warnings` clean.
- [ ] `forge test` 0 failures.
- [ ] `cast 4byte` selectors for new errors/events get `@custom:selector` natspec.
- [ ] PR body lists ABI changes (interface diff) and the deployment runbook delta (one less role to wire, no `setDefaultStrategy` post-deploy step).

## Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Interest accrual gap on idle deposits | High | Low (already accepted operationally) | Manager rebalance cadence covers; treasury covers user APY in the gap. |
| Withdrawal ordering surprise (no default-first) | Low | Low | Iteration order is `EnumerableSet` insertion order; manager controls add-order during deploy + addStrategy. Tests pin behavior. |
| External integrator depending on `getDefaultStrategy` view | Low (pre-launch) | Low | Pre-launch ABI break, expected. Document in PR body. |
| Re-add cost if we ever want default back | Low | Medium | Acceptable. The feature is a contained mapping + helpers; re-adding is a similarly-sized PR if needed. |

## Out of scope

- `enableDepositsToStrategy` / `disableDepositsToStrategy` — independent per-strategy flag, not affected.
- `topUp` — independent treasury-push entrypoint, no auto-deposit dependency.
- Rebalance flow — unchanged; manager still routes funds via `RebalanceParams`.
- Strategy add/remove flow — unchanged except for the auto-clear branch.
- Audit findings tied specifically to default-strategy: closed as a side-effect of removal; track in audit response doc.

## Open questions (resolved or to settle in spec)

| Question | Decision |
|---|---|
| Single `pullIdle` vs split `pullIdleStrict` (revert on zero) and `pullIdleAllowZero` (no-op on zero) | **Single function with zero-amount no-op** (matches bridge-callback safety pattern from old `depositAllowIdle`). Simpler. |
| Zero-amount semantics: revert vs no-op | **No-op** to preserve bridge-callback safety. |
| Should `processDeposit` keep its `returns (uint256)` signature | **Yes**, keep ABI-stable on the StableVault side; just always returns input amount. |

## References

- Linear: https://linear.app/aavelabs/issue/VA-157
- Slack thread: https://aavelabs.slack.com/archives/C09C7L5AGHW/p1778078357145069
- `src/core/Allocator.sol` deposit/withdraw flows (lines 162, 188-220, 222-256, 303-325, 596, 611)
- `src/interfaces/IAllocator.sol` DefaultStrategy event/error/getter/setter
