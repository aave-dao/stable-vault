# Deployment Smoke Tests Spec

## Metadata
- Project: stable-vault
- Milestone: 3. Scripts audit and pre-prod
- Linear Issue: [VA-229](https://linear.app/aavelabs/issue/VA-229/work-on-smoke-tests) (Urgent, 8 points)
- Interview Date: 2026-05-25
- Status: [x] Draft / [ ] Ready for Review / [ ] Approved

## Summary

A TypeScript + viem CLI under `tools/smoke/` that verifies, after every deploy, that the on-chain state of the stable-vault system matches the JSONC config that produced it. The harness reads each leaf of `config/deployment-config.<env>.jsonc` through a catalogue mirror of `tools/roles/lib/parameters-spec.ts`, compares to live on-chain values, and prints a terminal-friendly report that **shows the present on-chain value alongside the expected value for every check — even on pass**. A dated JSON report is archived under `tools/smoke/output/` for the audit trail.

The harness is the missing artefact between "the `forge script` broadcast succeeded" and "the deployed system is configured the way the operator intended." It is intended for both CI (run against a forked node on every deploy PR) and operator use (run against the live RPC after each real deploy).

## Requirements

### Functional

1. CLI invocation `tsx tools/smoke/run.ts --env <preprod|staging|prod> --chain <accounting|earning>` runs the smoke against the configured RPC, exits 0 on full pass.
2. Default output shows expected + on-chain values for every check, even on pass. `--summary`, `--quiet`, `--json` opt-in modes for compact / failure-only / machine-readable rendering.
3. Eleven check groups run per chain: Topology, AccessManager, AssetRegistry, Allocator, StableVault, WithdrawalExecutionPolicy, DepositPolicy, FundsBridgingPolicy, SlippageCoverageVault, Oracles, BridgeAdapters, IouTokenManager.
4. Topology check covers (a) CREATE3 re-derivation matches the recorded artefact, (b) `code.length > 0`, (c) `keccak256(actual.code) == keccak256(forge inspect <name> deployedBytecode)`, (d) ERC-1967 impl + admin slots match the artefact's `::Implementation` entries.
5. Parity check is driven by a getter catalogue (`tools/smoke/lib/catalogue/getters.ts`) keyed by the same `ParameterSpec.key` as `tools/roles/lib/parameters-spec.ts`. Adding a new parameter to the JSONC schema requires adding one matching getter entry — no other per-key code.
6. Live probes verify `PriceOracle.getPrice(asset) > 0` per asset, `ChainBalanceOracle.getChainBalance.isStale == false`, `CCIPRouter.isChainSupported(counterparty) == true`, L2 sequencer feed up.
7. Conditional contracts (AdiAdapter) and conditional config (mock feeds, TBD placeholders) handled gracefully: skip with explicit note, not silent pass.
8. JSON report written to `tools/smoke/output/<env>-<chain>-<ISO8601>.json` with `meta`, `groups[]`, `summary`, `warnings[]`, `errors[]`.
9. Exit codes: `0` pass, `1` parity/topology failure, `2` incomplete deploy, `3` RPC error, `4` config error.
10. Yarn scripts (`smoke:preprod`, `smoke:staging`, `smoke:prod`) and `make smoke ENV=<env> CHAIN=<chain>` target.

### Non-functional

- Under 5s end-to-end runtime on a healthy RPC.
- Deterministic: all multicalls pin to a single `blockNumber` captured at preflight.
- Read-only — no private keys, no broadcast.
- No emojis; Unicode box-drawing chars + `✓`/`✗` only.
- Mirrors the `tools/roles/` conventions (ESM, strict TS, `.js` suffix on relative imports, Node 22).

## Technical Design

### Architecture

```
tools/smoke/
├── run.ts                     # CLI entrypoint (env/chain dispatch, mode flags)
├── package.json               # Local "type": "module" for ora@9 ESM
├── tsconfig.json              # Extends tools/roles/tsconfig.json
├── lib/
│   ├── checks/                # One module per check group
│   ├── catalogue/getters.ts   # GETTER_SPECS mirrors parameters-spec.ts setters
│   ├── parity.ts              # Generic engine: getter ↔ JSONC leaf
│   ├── render.ts              # full / summary / quiet / json renderers
│   ├── create3.ts             # Port of Create3AddressLib.sol
│   ├── rpc.ts                 # viem public client + RPC URL resolution
│   ├── artefact.ts            # Load + index deployments/<env>/v1/<chain>.json
│   └── report.ts              # JSON report serialisation
└── output/.gitkeep
```

Reuses `tools/roles/lib/{parameters-spec,parameters,types,load-signatures}.ts` directly. New deps: `viem@^2.51.0`, `picocolors@^1.1.1`, `cli-table3@^0.6.5`, `ora@^9.4.0`, `boxen@^8`.

### Data sources

| Source | Path | Used for |
|---|---|---|
| JSONC config | `config/deployment-config.<env>.jsonc` | Expected values |
| Deployment artefact | `deployments/<env>/v1/<chain>.json` | Address ground-truth (verified against CREATE3 re-derivation) |
| Foundry artefacts | `out/<file>.sol/<Contract>.json` | ABI + `deployedBytecode` for parity getters + topology hash check |
| Live RPC | `SMOKE_RPC_<ENV>_<CHAIN>` env var or `--rpc <url>` | On-chain state |

### Order of operations

1. **Preflight** (no RPC): args, JSONC, TBD scan, artefact load, SHA capture.
2. **RPC handshake**: capture block number + chain id; assert chain id matches config.
3. **Topology** (pinned block): CREATE3 → code.length → bytecode hash → ERC-1967.
4. **Parity** (pinned block, parallel multicall): catalogue-driven reads + compares.
5. **Live probes** (parallel, current block): oracles + CCIP + sequencer.
6. **Cross-chain** (optional, v2).
7. **Render + report**.

## Implementation Plan

### Phase 1: Foundation
- [ ] Scaffold `tools/smoke/` directory + `package.json` + `tsconfig.json` (mirror `tools/roles/`)
- [ ] Port `Create3AddressLib.sol` → `lib/create3.ts` with golden tests against known preprod addresses
- [ ] Add viem + CLI deps to root `package.json`; pin per framework-docs research
- [ ] Add `.gitignore` entry for `tools/smoke/output/*.json`

### Phase 2: Core checks
- [ ] `lib/artefact.ts`: load + index `deployments/<env>/v1/<chain>.json`
- [ ] `lib/checks/topology.ts`: CREATE3 + code.length + bytecode hash + ERC-1967
- [ ] `lib/catalogue/getters.ts`: 1:1 with `PARAMETER_SPECS` (49 entries) — one getter per setter
- [ ] `lib/parity.ts`: generic engine over multicall + decoder + compare
- [ ] `lib/checks/{access,policies,registries,oracles,bridges}.ts`: thin per-group wrappers

### Phase 3: UX + reporting
- [ ] `lib/render.ts`: full / summary / quiet / json
- [ ] `lib/format.ts`: humaniser (RAY → $, seconds → readable, bps → %)
- [ ] `lib/report.ts`: JSON schema + write to `output/`
- [ ] `run.ts`: arg parsing, mode dispatch, exit-code policy

### Phase 4: Integration
- [ ] Yarn scripts (`smoke:run`, `smoke:preprod`, etc.)
- [ ] Makefile `smoke` target
- [ ] CI workflow: forked-anvil job that runs smoke against preprod config on every PR touching `config/` or `script/`

### Phase 5: Validation
- [ ] Run against preprod from a real RPC; capture baseline report
- [ ] Manually break a JSONC value and confirm smoke catches it
- [ ] Manually deploy with stale address in artefact and confirm topology catches it
- [ ] Confirm under-5s runtime target

## Test Plan

- [ ] Unit tests for: `create3.ts` (golden vectors against preprod addresses), `parity.ts` (table-driven compare against fixture pairs), `format.ts` (RAY/bps/seconds humaniser), `artefact.ts` (load + sanity)
- [ ] Integration tests for: full smoke run against a fixture anvil fork; expected-failure runs (wrong value, missing contract, bytecode mismatch)
- [ ] CI smoke against forked preprod on PRs touching `config/` or `script/`

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| viem multicall batch sizing wrong on Arbitrum | Medium | Low | Tune `batchSize` to 4096; fall back to `Promise.all` chunks |
| `forge inspect deployedBytecode` slow / flaky | Low | Medium | In-memory cache per run; CI pre-runs `forge build` |
| RPC 429 mid-run | Medium | Medium | Distinct exit code 3 (not parity fail); CI retries 2x |
| Per-asset catalogue drifts behind new assets | High | Low | Catalogue keyed by `parameters-spec.ts`; CI fails on gap |
| Cross-reference immutables drift undetected | Medium | Medium | Bytecode-hash equivalence as transitive proof (v1 decision) |
| Stale `deployments/<env>/v1/<chain>.json` artefact | Medium | High | CREATE3 re-derivation is canonical; artefact divergence = explicit `artefact-stale` error |

## Open Questions (Resolved)

| Question | Answer | Decided By |
|----------|--------|------------|
| Address source-of-truth | Verify CREATE3 re-derivation + artefact + live code; CREATE3 wins on conflict | Interview |
| Functional smoke in v1? | No — state assertions only; `--with-functional` deferred | Interview |
| CI integration shape | Both: PR CI against forked anvil + operator command for live deploys | Interview |
| Report archival | Stdout pretty + JSON under `tools/smoke/output/` (gitignored) | Interview |
| Default output detail | **Full per-check view with on-chain values**; `--summary` opt-in | Interview (new requirement) |
| Cross-reference immutables (no public getter) | v1: rely on topology bytecode-hash equivalence as transitive proof; defer public-accessor PR | Spec-flow analysis (M3) |
| Cross-chain shared-invariant mode | Deferred to v2 (`--check-cross-chain` flag) | Spec-flow analysis (M6) |
| TBD/zero-address policy | Warning by default; `--strict` promotes to failure | Spec-flow analysis (S1) |
| Per-chain oracle adapter naming | Catalogue keyed by chain (`ChainlinkPriceOracleAdapter` for EC, `ChainlinkL2*` for AC) | Spec-flow analysis (M4) |
| Conditional AdiAdapter | Three-state check: absent / deployed-not-registered / deployed-and-registered | Spec-flow analysis (M5) |

## Interview Notes
See: [interview-notes.md](./interview-notes.md)

## Technical Details
See: [technical-spec.md](./technical-spec.md)

## Research
See: [research/](./research/)
- [repo-analysis.md](./research/repo-analysis.md) — repo conventions, tools/roles patterns, artefact schema
- [best-practices.md](./research/best-practices.md) — Aave / Optimism / Compound prior art, viem batching, CLI libs
- [framework-docs.md](./research/framework-docs.md) — viem, tsx, jsonc-parser, picocolors pinned versions
- [specflow-analysis.md](./research/specflow-analysis.md) — must-fix gaps, exit-code policy, open decisions

---

## Approval
- [ ] Stakeholder Approved
- Approved date: ___

## Next Steps
After approval, run: `/dev:work specs/deployment-smoke-tests/technical-spec.md`
