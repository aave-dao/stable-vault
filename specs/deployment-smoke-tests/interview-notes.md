# Interview Notes — Deployment Smoke Tests

**Linear ticket:** [VA-229 — Work on smoke tests](https://linear.app/aavelabs/issue/VA-229/work-on-smoke-tests)
**Source:** Distilled from VA-229 discussion thread on 2026-05-25.
**Note:** Linear ticket has empty description, so requirements are derived from team conversation.

---

## Problem framing

After a deploy (or a partial deploy that was resumed via the PR 309 skip mechanism), there is no automated artefact that confirms the deployed system matches the JSONC configuration the operator intended to deploy. PR 309 adds pre-deploy validations and bytecode-equivalence skip checks, but nothing reads the on-chain state *after* deploy and asserts it matches the config. Smoke tests close that gap.

## Goal

Produce a deployment smoke-test harness that, after any deploy against any environment (preprod, staging, prod, or a fork), verifies:

1. **Topology** — every deployed contract has bytecode, ERC-1967 slots point at expected implementations, immutable cross-references between contracts are correctly wired.
2. **Config-to-on-chain parity** — every JSONC config leaf that becomes on-chain state matches the value read from the deployed contract.
3. **Live external dependencies** — `PriceOracle.getPrice` returns non-zero for each asset, `ChainBalanceOracle.getChainBalance` is fresh (not stale), `CCIPRouter.isChainSupported` returns true for the counterparty, L2 sequencer feed is up.

Functional smoke (tiny deposit/withdraw/rebalance against a fork) is **out of scope for v1**, deferred to a `--with-functional` mode in a later phase.

## Key design decisions (from discussion)

### Decision 1: Drive smoke tests from the parameters spec catalogue

PR 309 added `tools/roles/lib/parameters-spec.ts` which pairs every JSONC config key with the on-chain *setter* selector. The smoke test should follow the same shape: a sibling catalogue (or extension of the same file) that pairs every config key with the on-chain *getter*. The parity engine reads N values in parallel and compares — no per-key bespoke code. New parameters added to JSONC automatically get smoke-test coverage.

### Decision 2: TypeScript + viem, not Solidity or shell

Reasons:
- **JSON-heavy.** Config is JSONC; deployment artefact is JSON. TS handles varied JSON shapes (per-asset maps, nested policies) naturally; Solidity's `vm.parseJsonXxx` forces a fixed shape per call site; shell + `jq` is unreadable for nested maps.
- **Reuse.** PR 309 already adds `tools/roles/` (TS) for the Notion sync. Smoke tests live in `tools/smoke/` and re-import `tools/roles/lib/parameters-spec.ts`. Single source of truth for "what should be on-chain".
- **Terminal output.** `picocolors` + `cli-table3` + `ora` give clean output; viem provides typed contract clients; parallel RPC calls for fast runs.
- **CI runtime.** The Notion-sync CI already runs `tsx`; no new toolchain dep.

### Decision 3: Output present values by default — not just confirmation

Originally we considered a compact `X / Y ✓` summary view. After feedback, the default is now the **detailed view**: each check prints the actual on-chain value alongside the expected value, even on pass. The compact summary becomes a `--summary` opt-in flag. Rationale: smoke tests run rarely (once per deploy), so the verbose output is what an operator wants — they want to *see* the redemption cap, the role delays, the per-asset deposit caps as actually deployed.

Modes:
- **Default (full):** every check prints `key | expected | on-chain | ✓/✗`. Group headers separate sections.
- **`--summary`:** the compact `X / Y ✓` view for quick CI signal.
- **`--quiet`:** failures only.
- **`--json`:** machine-readable output, suppresses human view.

### Decision 4: Address source-of-truth — verify both

Both re-derive from CREATE3 (deployer + salt) and compare to the recorded `deployments/<env>/<v>/<chain>.json` artefact and compare to live on-chain code. This catches three failure modes:
- (a) Artefact tampering between deploy and smoke
- (b) Smoke run against the wrong env config
- (c) On-chain code present but doesn't match the expected bytecode (collision / stale prior deploy)

### Decision 5: CI integration — both manual and automated

- **CI automation:** on every deploy-touching PR, run the smoke harness against a fork of preprod and fail the build on diff. Provides regression coverage as the JSONC changes.
- **Operator command:** after each real deploy (preprod/staging/prod), the operator runs `tsx tools/smoke/run.ts --env <env> --chain <chain>` against the live RPC. Reports archived under `tools/smoke/output/` (gitignored).

### Decision 6: Report archival

Stdout-pretty for humans + JSON report under `tools/smoke/output/` (gitignored) for the audit trail. JSON filename pattern: `<env>-<chain>-<ISO-timestamp>.json`. The audit team can use these to track parity drift over time.

## What lives in scope for v1

| Check group | Coverage |
|---|---|
| **Topology** | code.length on every deployed address; ERC-1967 impl + admin slots on every transparent proxy; immutable cross-refs (StableVault.ASSET_REGISTRY etc.) point at deployed addresses; CREATE3 re-derivation matches artefact. |
| **AccessManager** | role grant delays match config (low/medium/high/critical); profile addresses match config; deployer's ADMIN_ROLE revoked; main/secondary admin role grants present. |
| **AssetRegistry** | per-asset deposit/swap/distrust flags match config; trusted-by-default state correct. |
| **Allocator** | trusted strategies registered; per-asset strategy list non-empty for required assets; deposit-allowed flags match. Earning chain: sGHO strategy registered for GHO. |
| **StableVault** | maxValidPerSecondRate, defaultSubVault rate, treasury address all match config. |
| **WithdrawalExecutionPolicy** | defaultFeeBps, signer address, redemption bucket capacity/refillRate/min floors match config. |
| **DepositPolicy** | per-asset capacity/refillRate match config. |
| **FundsBridgingPolicy** | per-route capacity/refillRate match config. |
| **SlippageCoverageVault** | maxSlippageBps, overrideMaxSlippageBps, override mode flag, per-asset pull caps + window caps + windowSeconds match config. |
| **PriceOracle** | min valid price ray, per-asset adapter address; live getPrice probe returns non-zero. |
| **ChainBalanceOracle** | per-chain adapter address; live getChainBalance returns isStale=false. |
| **BridgeAdapters (CCIP, a.DI)** | adapter whitelist per (asset, chainId); router/cross-chain-controller addresses; CCIP isChainSupported live probe; a.DI registerOnGateway flag matches config. |
| **IouTokenManager** | bridge route whitelist matches config; minBurnIouTokenGasLimit immutable matches. |

## Out of scope for v1

- Functional smoke (tiny deposit / requestWithdrawal / executeWithdrawal / rebalance against fork). Deferred to `--with-functional` flag in a later phase.
- Multi-deploy diff (comparing smoke output across two deploys to spot regression). Deferred.
- Auto-write to Notion (smoke results posted to a Notion DB). Deferred.

## Implementation skeleton (agreed)

```
tools/smoke/
├── run.ts                  # CLI entrypoint
├── lib/
│   ├── checks/
│   │   ├── topology.ts     # code.length, ERC-1967 slots, immutable refs
│   │   ├── access.ts       # role delays, profile assignments
│   │   ├── policies.ts     # generic parity over parameters-spec
│   │   ├── registries.ts   # AssetRegistry, Allocator, ChainBalanceOracle
│   │   ├── oracles.ts      # adapters + live getPrice probes
│   │   └── bridges.ts      # CCIP / a.DI whitelisting + live isChainSupported
│   ├── parity.ts           # Generic engine: getter ↔ JSONC leaf
│   ├── render.ts           # picocolors + cli-table3; full / summary / quiet / json
│   ├── rpc.ts              # viem clients per env/chain
│   └── format.ts           # Human-readable value formatting (RAY → $, seconds → readable, etc.)
└── tsconfig.json
```

Generic `parity.ts` is the load-bearing piece. It reads each `(jsonPath, contractName, getterSelector, decoder)` triple from the spec, calls the getter, decodes the response, compares against the JSONC leaf at the same path, emits a structured `CheckResult`. Render layer turns `CheckResult[]` into either the full table, summary, or JSON.

## Open questions resolved

| Question | Decision |
|---|---|
| Address source-of-truth | Verify CREATE3 re-derivation + artefact + live code |
| Functional smoke in v1? | No — state assertions only |
| CI integration shape? | Both automated PR CI (fork) and operator command (live RPC) |
| Report archival? | Stdout pretty + JSON under `tools/smoke/output/` (gitignored) |
| Output detail level? | Full per-check view with values is default; `--summary` is opt-in |

## Reference output mockup (default mode)

```
╔════════════════════════════════════════════════════════════════════════════╗
║  stable-vault smoke • preprod • arbitrum-sepolia • commit 279d0c96         ║
╚════════════════════════════════════════════════════════════════════════════╝

▸ Topology
  ✓ StableVault                 0xa1b2…cdef    24,584 bytes  → proxy → 0x9d…
  ✓ AssetRegistry               0xf3a4…1234    16,201 bytes  → proxy → 0x44…
  ...

▸ Access control — delays
  ✓ lowDelay                    1,800s    (30m)
  ✓ mediumDelay                 2,700s    (45m)
  ✓ highDelay                   3,600s     (1h)
  ✓ criticalDelay               7,200s     (2h)

▸ Access control — profile assignments
  ✓ mainAdmin                   0x3641…C6a5
  ✓ secondaryAdmin              0x1eD5…2093
  ...

▸ FundsBridgingPolicy.perAssetLimits.gho
  ✓ capacity                    500000000000000000000      (500 GHO)
  ✓ refillRate                  5787037037037037           (500 GHO/day)

▸ Oracles — live probes
  ✓ PriceOracle.getPrice(GHO)   997000000000000000000000000  (≈ $0.997)
  ✓ ChainBalanceOracle(EC=1)    isStale=false  age=42s  lastBlock=23456789
  ✓ CCIPRouter.isChainSupported(EC) true

143 checks · 143 passed · 0 failed · 2.4s
Report: tools/smoke/output/preprod-accounting-2026-05-25T14:30:11Z.json
```

On failure:

```
▸ FundsBridgingPolicy.perAssetLimits.gho
  ✓ refillRate                  5787037037037037           (500 GHO/day)
  ✗ capacity                    expected 500000000000000000000     (500 GHO)
                                actual   1000000000000000000000000 (1,000,000 GHO)
                                setter   FundsBridgingPolicy.raiseCapacity (mediumDelay)
```
