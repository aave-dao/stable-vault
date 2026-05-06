# SpecFlow Analysis — SlippageCoverageVault

Synthesized from interview-notes.md + repo-analysis.md + best-practices.md + framework-docs.md.

## Coverage of attack paths (Path A/B/C/D from v3)

| Path | Closed by | Test selector |
|---|---|---|
| A. Direct drain via OwnedMulticall | Vault holds funds; OwnedMulticall holds none | `test_pullCoverage_reverts_ifCallerIsNotRecipient`, integration: vault balance non-decreasing under `aggregate3` calls from manager |
| B. Malicious swapper passed as `swap.swapper` | `msg.sender == SLIPPAGE_RECIPIENT` gate; evil swapper has no funds → Allocator 1:1 invariant reverts | `test_pullCoverage_reverts_ifCallerIsNotRecipient`; integration: malicious swapper rebalance reverts |
| C-1. `transferFrom(coverage, attacker)` injected in target loop | No allowances exist; vault is push-only | implicit (no allowance to test) |
| C-2. `slippageToleranceBps = 99%` | Bounded `MAX_BPS` slippage tolerance read from vault storage | `test_executeSwap_reverts_ifSlippageToleranceAboveMax` |
| C-3. `assetIn` redirected inside loop | `balanceOf(assetIn) == 0` invariant after loop | `test_executeSwap_reverts_ifAssetInLeftover` |
| C-4. `targets[i] = vault` to call `pullCoverage` directly inside loop | `targets[i] != SLIPPAGE_VAULT` guard | `test_executeSwap_reverts_ifTargetIsVault` |
| D. Manager pre-approves attacker via OwnedMulticall | Vault holds no tokens to approve; never calls `approve` | implicit + `invariant_noApproveCalled` (out of scope per Decision #7 but recommended) |

All four paths covered. No gaps.

## User flow completeness

### Happy path: rebalance with slippage

1. Allocator calls `Swapper.executeSwap(assetIn, assetOut, amountIn, msgSender, data)`.
2. Swapper runs target loop; legit DEX trade lands `< expectedAmountOut` of `assetOut` into Swapper.
3. Swapper checks `assetIn` leftover == 0 (Hardening 3).
4. Shortfall `slippageAmount = expectedAmountOut - amountOut`.
5. Swapper checks `slippageBps <= maxBps` (governance-tunable, read from vault).
6. Swapper calls `vault.pullCoverage(assetOut, slippageAmount)`.
7. Vault checks `msg.sender == SLIPPAGE_RECIPIENT`, applies caps (per-tx + window) unless override mode.
8. Vault `safeTransfer(assetOut, msg.sender, slippageAmount)`. Emits `CoveragePulled(asset, amount, overrideMode)`.
9. Swapper `forceApprove(allocator, expectedAmountOut)`.
10. Allocator pulls `assetOut`. 1:1 invariant holds.

### Happy path: emergency rebalance under override

1. OPERATIONAL_GUARDIAN calls `vault.setOverrideMode(true)`. Emits `OverrideModeSet(true)`.
2. Operator runs rebalance with `slippageBps = 5000` (50%).
3. Swapper reads `maxBps` from vault → returns 5000 in override mode.
4. Vault skips per-tx + window cap checks; emits `CoveragePulled` with `overrideMode = true`.
5. After emergency, OPERATIONAL_GUARDIAN calls `vault.setOverrideMode(false)`. Emits `OverrideModeSet(false)`.

### Edge cases enumerated

| Edge case | Handling |
|---|---|
| Vault deployed but unfunded | `pullCoverage` reverts via `safeTransfer` (`SafeERC20FailedOperation`). Operator tops up then retries. |
| Cap raised mid-window | New cap applies; `consumed` not reset (documented in NatSpec). |
| Cap lowered mid-window | If `consumed > newCap`: subsequent pulls revert until rollover. Document. |
| Window seconds = 0 | `setWindowCap` reverts (`InvalidParameter`). |
| `windowStart == 0` (first call) | Rollover triggers, sets `windowStart = block.timestamp`, `consumed = amount`. Tested. |
| `pullCoverage(asset, 0)` | Revert (`InvalidAmount`). |
| `pullCoverage(unconfigured asset, amount)` | `pullCapPerTx[asset] == 0` → `ExceedsPerTxCap`. |
| Override flipped between two pulls in same block | First pull in override mode, second pull normal mode. Tested. |
| `topUp` race with `pullCoverage` | Acceptable; `safeTransfer` reverts on insufficient balance; operator retries after `topUp`. |
| Non-bound caller calls `pullCoverage` | `OnlyRecipient` revert. |
| Recipient is address(0) at construction | Constructor revert (`Errors.ZeroAddress`). |
| Sweep to zero address | Revert (`Errors.ZeroAddress`). |
| Sweep amount > balance | `safeTransfer` revert. |
| Pause/upgrade then resume | Window state preserved (lazy init); first post-resume pull either rolls over (if elapsed) or continues consuming. |

## Acceptance criteria gaps

The interview-notes acceptance list is comprehensive. Updates:

- **Test naming**: change `test_X_revertWhen_Y` → `test_X_reverts_ifY` per repo convention (see `repo-analysis.md` §5).
- **Add**: `test_pullCoverage_firstCallRollsOverFromZero` (default-state edge case).
- **Add**: `test_setOverrideMode_flipBetweenPulls_secondPullRespectsCaps`.
- **Add**: `test_setPullCapPerTx_raise_requiresAdminWithDelay` and `test_setPullCapPerTx_lower_requiresOperationalNoDelay` (directional ACL).
- **Add**: `test_pullCoverage_assetInDelta_capCountsGrossNotNet` — explicit FoT/rebasing decision documented (revert on FoT? or accept gross-counts? Decide and test).
- **Confirm**: `test_swapper_constructor_reverts_ifSlippageVaultIsZero`.
- **Add**: `test_swapper_redeploy_invalidatesOldAccessManagerGrants` — document via PR-body wiring delta, test optional.

## Risk gaps

- **Boundary burst at fixed-window rollover** (cap × 2 in 1 second). Either:
  - Accept and document; treasury sizes `windowCap` to absorb.
  - Switch to token bucket (CCIP `RateLimiter` pattern) — best-practices recommendation.
- **FoT / rebasing token policy**: not yet decided. Recommend ACL-curated asset list (governance excludes FoT), document explicitly in spec.
- **Slippage bound storage location**: Decision #5 said "governance-tunable", but on which contract? Recommendation per repo conventions: store on Vault (single source of truth, AccessManager wiring lives there); Swapper reads via `vault.getMaxSlippageBps()` / `vault.getOverrideMaxSlippageBps()`. Avoids dual-ACL surface.
- **Default cap values**: `pullCapPerTx[asset] = 0` rejects all pulls. Confirm spec: vault unusable until governance sets per-asset caps post-deploy. Document in deployment ticket.

## Order of operations for implementation

1. `ISlippageCoverageVault.sol` — interface, errors, events, struct(s).
2. `SlippageCoverageVault.sol` — impl + ERC-7201 storage + AccessManaged + initializer.
3. Update `ISwapper.sol` — move `SlippageParams`, drop `slippageCoverageSource`, add new errors (`BadTarget`, `AssetInLeftOver`, `SlippageToleranceTooHigh`).
4. Update `Swapper.sol` — immutable `SLIPPAGE_VAULT`, hardenings 1/2/3, swap to `pullCoverage`.
5. Tests in interleaved order:
   - Vault unit tests (caps, override, roles, sweep, topUp, immutability).
   - Swapper unit tests (hardenings, integration with vault).
   - Update `OwnedMulticall.t.sol` integration test (now uses vault).
6. Deployment wiring: `Create3AddressBook` + `EarningChainDeployment` + `AccountingChainDeployment` + `AccessManagerBaseSetup` + `RolesConfig`.
7. PR body: Stermi I-06/I-14, Certora M-01, Recon-Fuzz #22 + #33 disposition; wiring delta; deployment redeploy notes.
