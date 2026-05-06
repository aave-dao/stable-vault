# SlippageCoverageVault — Interview Notes

**Date:** 2026-05-06
**Driver:** João Martins
**Linear:** VA-96 — `[Stermi I-06/I-14] [Certora M-01] SlippageCoverageVault — isolate coverage funds from OwnedMulticall`
**Branch (Linear):** `joao/va-96-stermi-i-06i-14-certora-m-01-slippagecoveragevault-isolate`
**Closes:**
- Stermi I-06 (rebalance not timelocked, arbitrary swapper)
- Stermi I-14 (Swapper arbitrary calls, slippageCoverageSource trust boundary)
- Certora M-01 (capital problem — partially; capital sizing is treasury's lane)
- Recon-Fuzz #22 (https://github.com/Recon-Fuzz/aave-review/issues/22)
- Recon-Fuzz #33 — Swapper line (https://github.com/Recon-Fuzz/aave-review/issues/33#issuecomment-4377337057)

## Source of truth

The Linear issue VA-96 description is the authoritative v3 analysis. This file captures the scoping decisions taken in the 2026-05-06 interview round on top of that v3 baseline; everything not contradicted here stays as written in Linear.

## Problem (recap)

Coverage funds for Allocator rebalance swaps live in `OwnedMulticall`. A compromised manager EOA owning the OwnedMulticall has four independent drain paths:

| Path | Vector |
|---|---|
| A — Direct drain | `aggregate3([{token, transfer(attacker, balance)}])` — unrestricted owner `call()` |
| B — Malicious swapper | Manager passes evil `swap.swapper`; coverage tops up Allocator's 1:1 invariant; assetIn stolen |
| C — Legit swapper, manipulated params | `transferFrom(coverageSource, attacker)` injected in target loop; or `slippageToleranceBps = 99%`; or assetIn redirected inside loop |
| D — Approval bypass | Manager pre-approves attacker via OwnedMulticall, then drains via `transferFrom` |

Allocator's `amountOut >= expectedAmountOut` invariant is *asymmetric* — checks `assetOut` only, not `assetIn`. Paths A/D bypass the Allocator entirely; B/C exploit the asymmetry plus the unbounded `slippageToleranceBps` plus the call loop's reach into approved coverage.

## Solution (v3 baseline from Linear)

Three components, ship together as one PR:

1. **`SlippageCoverageVault`** (new contract) — push-based, immutable `SLIPPAGE_RECIPIENT` (the bound Swapper). Holds coverage capital instead of OwnedMulticall. `pullCoverage` is the only outflow; `IERC20.approve` never used.
2. **`Swapper` hardenings** — `target != SLIPPAGE_VAULT` guard in call loop; bounded slippage tolerance; zero-leftover `assetIn` invariant; `slippageCoverageSource` removed from `SlippageParams` (vault implicit via immutable binding).
3. **No Allocator changes** — `_swap` 1:1 invariant stays as-is. No Allocator-side coverage-source whitelist, no Allocator-side swapper whitelist (both redundant under the push-based vault).

## Scoping decisions (2026-05-06)

| # | Decision | Choice | Reasoning |
|---|---|---|---|
| 1 | Rate-limit shape on the vault | **Both per-tx cap and sliding-window cap** | Per-tx bounds single-call drain (Path C residuals); window bounds cumulative drain regardless of call count (sustained compromise before guardian SLA fires). Window-only would let one bad call drain the full daily window; per-tx-only would let `pullCapPerTx × N_calls` accumulate. |
| 2 | Override mode TTL | **Manual revert by guardian only** | Auto-expire adds a storage slot + comparison logic for marginal safety. Guardian holds the flag and is responsible for cleanup. Trilemma logic in v3 stands as written. |
| 3 | Capital migration from current OwnedMulticall | **Greenfield — no migration in this PR** | Stable Vault has not launched. Vault is deployed empty; treasury funds via `topUp` post-deploy. Deployment ticket handles funding wiring. |
| 4 | Coverage of Recon-Fuzz #33 | **Yes — close #33 Swapper line under this spec** | v3 design exactly matches Gallo's recommendation: rate limit on `slippageCoverageSource`, not on swap volume. Spec doc references both #22 and #33 as resolved by the same change. |
| 5 | Slippage tolerance bounds (MAX_BPS / OVERRIDE_BPS) | **Governance-tunable storage** (divergence from v3) | Stored on the Vault (or Swapper) behind HIGH_DELAY / ADMIN. Avoids a Swapper redeploy when bounds need tuning post-launch. v3 had these as immutable constants — overridden here for operational flexibility. |
| 6 | Swapper ↔ Vault binding | **Strict immutable on both sides** | `Swapper.SLIPPAGE_VAULT` and `Vault.SLIPPAGE_RECIPIENT` both immutable. Rotation requires redeploying both + AccessManager re-wire. Maximum trust isolation; no setter to compromise. |
| 7 | Test scope | **Unit + adversarial unit tests** | Each Path A/B/C/D drain attempt as explicit named test. Fast, audit-readable, covers the specific findings being closed. Invariant/Echidna out of scope; if Recon adds invariants downstream that's fine. |

## Acceptance criteria (full)

### Vault contract (`SlippageCoverageVault`)
- [ ] New contract `src/periphery/SlippageCoverageVault.sol` (or `src/core/...` — to be confirmed in technical spec) inheriting `AccessManagedUpgradeable`.
- [ ] Immutable `SLIPPAGE_RECIPIENT` set at construction; cannot be changed.
- [ ] `pullCoverage(address asset, uint256 amount)` callable only by `SLIPPAGE_RECIPIENT` (revert: `OnlyRecipient`).
- [ ] In normal mode: enforce `amount <= pullCapPerTx[asset]` (revert: `ExceedsPerTxCap`).
- [ ] In normal mode: enforce sliding-window cap via `_consumeWindow(asset, amount)` (revert: `ExceedsWindowCap`). Window state per asset.
- [ ] In override mode: bypass both per-tx and window caps; emit `CoveragePulled` with override flag.
- [ ] `setOverrideMode(bool)` — `OPERATIONAL_ROLE_GUARDIAN_ROLE`, no delay.
- [ ] `setPullCapPerTx(address asset, uint256 cap)` — directional ACL: raise = ADMIN + HIGH_DELAY, lower = OPERATIONAL + no-delay.
- [ ] `setWindowCap(address asset, uint256 cap, uint64 windowSeconds)` — same directional ACL.
- [ ] `topUp(address asset, uint256 amount)` — `OPERATIONAL_ROLE_GUARDIAN_ROLE`, no delay. Pulls from caller via `safeTransferFrom`.
- [ ] `sweep(address asset, uint256 amount, address to)` — ADMIN + HIGH_DELAY, critical role.
- [ ] No `IERC20.approve` ever called from this contract.
- [ ] Events: `CoveragePulled`, `OverrideModeSet`, `PullCapPerTxSet`, `WindowCapSet`, `ToppedUp`, `Swept`.

### Swapper hardenings
- [ ] `SLIPPAGE_VAULT` immutable, set at construction.
- [ ] `slippageCoverageSource` field removed from `SlippageParams`.
- [ ] Slippage tolerance bounds read from vault (or swapper) governance-tunable storage at call time. Default sizing aligned with v3 (MAX = 1%, OVERRIDE = 50%) but writable via setter behind HIGH_DELAY/ADMIN.
- [ ] Hardening 1: `targets[i] != SLIPPAGE_VAULT` for every i (revert: `BadTarget`).
- [ ] Hardening 2: `slippageParams.slippageToleranceBps <= maxBps` where `maxBps` toggles by override mode (revert: `SlippageToleranceTooHigh`).
- [ ] Hardening 3: `IERC20(assetIn).balanceOf(address(this)) == 0` after the call loop (revert: `AssetInLeftOver`).
- [ ] Coverage pulled via `ISlippageCoverageVault(SLIPPAGE_VAULT).pullCoverage(assetOut, slippageAmount)`.

### Allocator
- [ ] No code changes required. Document in PR body that the existing `amountOut >= expectedAmountOut` invariant remains the gate on the return leg.

### Tests (adversarial, named per attack path)
- [ ] `test_executeSwap_revertWhen_targetIsVault` — Path C (vault in target loop).
- [ ] `test_executeSwap_revertWhen_slippageToleranceAboveMax` — Path C (99% tolerance).
- [ ] `test_executeSwap_revertWhen_assetInLeftover` — Path C (assetIn redirection).
- [ ] `test_pullCoverage_revertWhen_callerIsNotRecipient` — Path B (malicious swapper).
- [ ] `test_pullCoverage_respectsPerTxCap` — Path C (manipulated params bounded).
- [ ] `test_pullCoverage_respectsWindowCap` — sustained compromise bounded.
- [ ] `test_pullCoverage_overrideModeBypassesCaps` — emergency rebalance works.
- [ ] `test_setOverrideMode_onlyOperationalGuardian` — role enforcement.
- [ ] `test_sweep_onlyAdminWithDelay` — critical role enforcement.
- [ ] `test_constructor_revertWhen_recipientIsZero` — defense.
- [ ] `test_swapper_pullsCoverageOnShortfall_underNormalMode` — happy path.
- [ ] `test_swapper_pullsCoverageOnShortfall_underOverrideMode` — happy path with high tolerance.

### Sequencing / acceptance gates
- [ ] Vault and Swapper hardenings ship in the same PR.
- [ ] Deployment doc note: vault deployed alongside Swapper; AccessManager wires roles per the table in Linear v3.
- [ ] PR body links Stermi I-06 / I-14, Certora M-01, Recon-Fuzz #22, Recon-Fuzz #33 with the disposition for each.

## Technical decisions

- **Storage namespace:** ERC-7201 slot for the vault (e.g. `aave.storage.SlippageCoverageVault`) — derive constant per repo convention.
- **Sliding window data structure:** per-asset `Window { uint64 windowStart, uint64 windowSeconds, uint256 cap, uint256 consumed }`. On pull: if `now > windowStart + windowSeconds`, roll over (`windowStart = now; consumed = amount`); else `require(consumed + amount <= cap)` then `consumed += amount`.
- **Slippage bound storage:** stored on the Vault (single source of truth — Swapper reads it). Avoids two roles to manage.
- **AccessManager wiring:** roles per the table in v3; both contracts inherit `AccessManagedUpgradeable`; setter modifiers `restricted`.
- **Swapper redeploy:** required because `SLIPPAGE_VAULT` is immutable. Allocator's `swap.swapper` field remains a runtime parameter; the deployed canonical Swapper is just whitelisted-by-convention.
- **Native asset:** vault is ERC-20 only. WETH-style wrapping if ever needed, not in v1.

## Risks

| Risk | Mitigation |
|---|---|
| Window-cap clock-skew griefing (manager calls just before rollover, then again right after, doubling the effective window) | Accept — analogous risk exists in any sliding-window bucket. Window sized for treasury comfort, not minute-level precision. |
| Governance setter delay misconfigured (e.g. raise treated as lower) | ACL split on the function signature, not on the value compared to current. Two functions or `restricted(roleId)` selector mapping in AccessManager. Document explicitly in deployment ticket. |
| Swapper redeploy invalidates existing AccessManager grants | Deployment ticket re-wires; PR body lists the wiring delta. |
| `topUp` race with `pullCoverage` causing temporary depletion | Acceptable — treasury monitors balance; `pullCoverage` reverts on insufficient balance, manager re-tries after `topUp`. |
| Slippage bound setter compromised (admin lifts MAX to 50% in normal mode) | Critical role + HIGH_DELAY on raises. Window cap still bounds total drain. |

## Out of scope (explicit)

- Capital sizing of the vault (Certora M-01 — treasury's lane).
- Allocator-side `isWhitelistedSwapper` or `isWhitelistedCoverageSource` whitelist (redundant under push-based vault per v3).
- Migration of pre-deployed funds (greenfield).
- Native-asset coverage support.
- Echidna / Medusa invariant suite (unit + adversarial unit only).
- Override mode auto-expiry / TTL (manual revert only).

## References

- Linear: https://linear.app/aavelabs/issue/VA-96
- Notion analysis: https://www.notion.so/aave/Jo-o-s-analysis-Swapper-SlippageCoverageSource-3569d63a22de80f5b297d3e947803303
- Recon-Fuzz #22: https://github.com/Recon-Fuzz/aave-review/issues/22
- Recon-Fuzz #33 (Caps & Rate Limits): https://github.com/Recon-Fuzz/aave-review/issues/33#issuecomment-4377337057
- Stermi I-06, I-14, Certora M-01 — see Linear description.
- João J-06 partially trusted roles: see Linear description.
- Josselin slack thread: https://aavelabs.slack.com/archives/C0A923NS69W/p1777394600203919
