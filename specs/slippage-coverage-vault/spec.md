# SlippageCoverageVault Spec

## Metadata
- Project: stable-vault
- Milestone: 2. Certora/GetRecon & Final Contract changes
- Linear Issue: VA-96
- Interview Date: 2026-05-06
- Status: [x] Draft / [ ] Ready for Review / [ ] Approved
- Closes: Stermi I-06, Stermi I-14, Certora M-01 (capital-isolation), Recon-Fuzz #22, Recon-Fuzz #33 (Swapper line)

## Summary

Replace `OwnedMulticall` as the slippage-coverage source for Allocator rebalance swaps with a purpose-built, push-based `SlippageCoverageVault` and harden the existing `Swapper`. The vault holds coverage capital, accepts pulls only from an immutable bound `Swapper`, and bounds losses with per-transaction and sliding-window caps per asset. An override mode (manual flip by guardian, separate role from rebalancer) bypasses caps for emergency rebalances. Allocator stays unchanged.

The current architecture has four independent drain paths if the manager EOA is compromised — three of which bypass the Allocator's 1:1 invariant entirely. This change closes all four structurally: the vault holds the capital (paths A, D become moot), the immutable recipient gate rejects malicious swappers (path B), and three Swapper-internal asserts close the manipulated-params variants (path C).

## Requirements

### Functional
1. New `SlippageCoverageVault` contract holding coverage capital; immutable `SLIPPAGE_RECIPIENT` (the bound Swapper) is the sole authorized puller.
2. `pullCoverage(asset, amount)` enforces per-tx cap and sliding-window cap per asset in normal mode; bypasses both in override mode.
3. Override mode is a manual boolean flip by `OPERATIONAL_GUARDIAN`, distinct from the rebalancer role. No TTL.
4. Cap setters split by direction: `raise*` requires ADMIN+HIGH_DELAY+critical; `lower*` requires OPERATIONAL+NO_DELAY.
5. Slippage tolerance bounds (normal MAX, override MAX) are governance-tunable storage on the vault, ADMIN+HIGH_DELAY+critical.
6. `topUp` (OPERATIONAL+NO_DELAY) and `sweep` (ADMIN+HIGH_DELAY+critical) for treasury operations.
7. Vault never calls `IERC20.approve` — push-based by construction.
8. Swapper hardenings: immutable `SLIPPAGE_VAULT`; `targets[i] != SLIPPAGE_VAULT`; `slippageBps <= maxBps` from vault; `balanceOf(assetIn) == 0` after target loop.
9. `slippageCoverageSource` removed from `SlippageParams`. `SlippageParams` moved from `Swapper.sol` to `ISwapper.sol`.
10. Allocator: no code changes; existing 1:1 invariant on `assetOut` is preserved.

### Non-Functional
- All custom errors carry `@custom:selector 0x________` natspec (repo convention).
- ERC-7201 namespaced storage (`aave.storage.SlippageCoverageVault`).
- `forge build --deny warnings` passes; `forge test` passes 10_000 fuzz runs.
- `nonReentrant` (transient) on `pullCoverage`, `topUp`, `sweep`.
- Test naming: `test_<fn>_reverts_<cond>` (repo convention).

## Technical Design

### Architecture

```
                ┌─────────────────────────────┐
                │   SlippageCoverageVault     │  AccessManagedUpgradeable
                │  ─────────────────────────  │  ERC-7201 storage
                │  immutable SLIPPAGE_RECIPIENT
                │  pullCapPerTx[asset]        │
                │  windowByAsset[asset]       │
                │  overrideMode (bool)        │
                │  maxSlippageBps             │  governance-tunable
                │  overrideMaxSlippageBps     │  governance-tunable
                └────────────┬────────────────┘
                  safeTransfer (push)
                             │
                             ▼
   ┌────────────┐     ┌────────────────────────┐
   │ Allocator  │────▶│   Swapper              │  immutable SLIPPAGE_VAULT
   │ (no change)│     │  target loop + 3 asserts:
   └────────────┘     │   • targets[i] != SLIPPAGE_VAULT
                     │   • slippageBps <= maxBps
                     │   • balanceOf(assetIn) == 0
                     │  pullCoverage on shortfall
                     └────────────────────────┘
```

`OwnedMulticall` is no longer a coverage source. It remains a batch-execution proxy for the manager but holds no tokens. Drain paths A and D close because there's nothing to drain.

### Data Model

```solidity
// ISlippageCoverageVault
struct Window {
    uint64  windowStart;
    uint64  windowSeconds;
    uint128 consumed;
    uint128 cap;
}

// ERC-7201 namespaced storage on SlippageCoverageVault
struct SlippageCoverageVaultStorage {
    bool overrideMode;
    uint16 maxSlippageBps;
    uint16 overrideMaxSlippageBps;
    mapping(address asset => uint256) pullCapPerTx;
    mapping(address asset => Window) windowByAsset;
}

// ISwapper (modified)
struct SlippageParams {
    uint16 slippageToleranceBps;  // slippageCoverageSource removed
}
```

### API Changes

**New `ISlippageCoverageVault` surface:**

```solidity
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
```

**Modified `Swapper` constructor:** `Swapper(address allocator, address slippageVault)`. Both addresses immutable.

**Removed from public API:** `SlippageParams.slippageCoverageSource`.

**Allocator:** unchanged.

### AccessManager wiring

| Selector | Role | Delay | Guardian | Critical |
|---|---|---|---|---|
| `pullCoverage` | — (gated by `msg.sender == SLIPPAGE_RECIPIENT`) | — | — | — |
| `setOverrideMode` | function-based | NO_DELAY | OPERATIONAL | false |
| `raisePullCapPerTx` | function-based | HIGH_DELAY | ADMIN | true |
| `lowerPullCapPerTx` | function-based | NO_DELAY | OPERATIONAL | false |
| `raiseWindowCap` | function-based | HIGH_DELAY | ADMIN | true |
| `lowerWindowCap` | function-based | NO_DELAY | OPERATIONAL | false |
| `setMaxSlippageBps` | function-based | HIGH_DELAY | ADMIN | true |
| `setOverrideMaxSlippageBps` | function-based | HIGH_DELAY | ADMIN | true |
| `topUp` | function-based | NO_DELAY | OPERATIONAL | false |
| `sweep` | function-based | HIGH_DELAY | ADMIN | true |

`setOverrideMode` is held by a role distinct from the rebalance manager.

## Implementation Plan

### Phase 1: Contract foundation
- [ ] `src/interfaces/ISlippageCoverageVault.sol` — events, errors, struct, interface.
- [ ] Compute ERC-7201 slot for `aave.storage.SlippageCoverageVault`.
- [ ] `src/periphery/SlippageCoverageVault.sol` — implementation.
- [ ] Update `src/interfaces/ISwapper.sol`: move `SlippageParams`, drop `slippageCoverageSource`, add new errors.
- [ ] Update `src/periphery/Swapper.sol`: immutable `SLIPPAGE_VAULT`, three hardenings, `pullCoverage` call, length check.

### Phase 2: Tests
- [ ] `test/unit/periphery/SlippageCoverageVault.t.sol` — full vault unit suite.
- [ ] Update `test/unit/periphery/Swapper.t.sol` — new constructor, hardening tests, drop `slippageCoverageSource` tests.
- [ ] Update `test/unit/periphery/OwnedMulticall.t.sol::test_rebalance_viaOwnedMulticall_swapWithSlippageCoverage`.
- [ ] Add `test_rebalance_viaOwnedMulticall_attemptDirectVaultCallReverts` (Path A regression).

### Phase 3: Deployment wiring
- [ ] `script/base/Create3AddressBook.sol` — new salt seed + address helper.
- [ ] `script/base/EarningChainDeployment.sol` and `AccountingChainDeployment.sol` — `_deploySlippageCoverageVault` + updated `_deploySwapper`.
- [ ] `script/base/AccessManagerBaseSetup.sol` — `_setupTarget__SlippageCoverageVault` + Rebalancer profile grant for `topUp`.
- [ ] `script/base/RolesConfig.sol` — one `getRole__<setter>()` per restricted entrypoint per the table above; append to `getAllFunctionBasedRoles()`.

### Phase 4: PR / handoff
- [ ] PR title: `feat(SlippageCoverageVault): isolate slippage coverage from OwnedMulticall (VA-96)`.
- [ ] PR body lists Stermi I-06/I-14, Certora M-01, Recon-Fuzz #22 + #33 disposition; role wiring delta; Swapper-redeploy notes.
- [ ] Comment on Recon-Fuzz #22 and #33 with merged-PR link.
- [ ] Move VA-96 to In Review.

## Test Plan
- [ ] **Unit (vault):** constructor revert; pullCoverage gating + caps + window + override; setter ACL split (raise/lower); topUp; sweep; events; rollover boundary.
- [ ] **Unit (Swapper):** constructor revert; Hardening 1 (target=vault revert); Hardening 2 (slippage > max revert in normal and override modes); Hardening 3 (assetIn leftover revert); length-mismatch revert; happy path with vault pull; emergency happy path.
- [ ] **Integration:** rewritten `test_rebalance_viaOwnedMulticall_swapWithSlippageCoverage` (vault as source); `test_rebalance_viaOwnedMulticall_attemptDirectVaultCallReverts` (Path A regression).
- [ ] **Out of scope (per Decision #7):** Echidna/Medusa invariants; documented as v2 follow-up.

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Boundary 2x-burst at fixed-window rollover | Medium | Low | Document; v2 token-bucket follow-up |
| FoT / rebasing token registered post-launch | Low | Medium | Asset-registry governance gating; document non-FoT assumption |
| Window-cap clock-skew griefing | Low | Low | Treasury-comfort sizing |
| Governance setter delay misconfigured | Medium | High | Directional split by selector name; deployment dry-run |
| Swapper redeploy invalidates AccessManager grants | High (expected) | Medium (operational) | PR body + deployment ticket re-wires |
| `topUp`/`pullCoverage` race causing temporary depletion | Medium | Low | Off-chain monitor; manager retries |
| Slippage bound setter compromised | Low | Medium | Critical role + HIGH_DELAY; window cap still bounds |
| Override mode armed and forgotten | Low | High | Off-chain alerts on `OverrideModeSet(true)`; manual revert chosen over TTL to keep operator accountable |

## Open Questions (Resolved)

| Question | Answer | Decided By |
|---|---|---|
| Per-tx cap, window cap, or both? | **Both** (defense-in-depth on two axes) | Joao, 2026-05-06 |
| Override mode TTL? | **No** — manual revert by guardian only | Joao, 2026-05-06 |
| Capital migration? | **Greenfield** — vault deployed empty, treasury funds post-deploy | Joao, 2026-05-06 |
| Does this close Recon-Fuzz #33? | **Yes** — Swapper line resolved by same change | Joao, 2026-05-06 |
| Slippage bounds: constants or governance? | **Governance-tunable** (divergence from v3 doc; avoids Swapper redeploy for tuning) | Joao, 2026-05-06 |
| Swapper↔Vault binding: rotatable? | **Strict immutable on both sides** | Joao, 2026-05-06 |
| Test scope beyond unit? | **Unit + adversarial unit only**; invariants out of scope | Joao, 2026-05-06 |

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
After approval, run: `/dev:work specs/slippage-coverage-vault/technical-spec.md`
