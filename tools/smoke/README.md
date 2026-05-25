# tools/smoke — deployment smoke tests

Reads `config/deployment-config.<env>.jsonc` + `deployments/<env>/v1/<chain>.json`, calls the live RPC, and asserts the deployed system matches its config. Output shows the present on-chain value next to the expected value on every check, even on pass.

Linear: [VA-229](https://linear.app/aavelabs/issue/VA-229/work-on-smoke-tests). Spec: `specs/deployment-smoke-tests/`.

## Run

```sh
# Operator: live RPC after a real deploy
SMOKE_RPC_PREPROD_ACCOUNTING=https://arb-sepolia.example/abc tsx tools/smoke/run.ts --env preprod --chain accounting

# Or via yarn
yarn smoke:preprod:accounting

# Or via make
make smoke ENV=preprod CHAIN=accounting

# RPC URL override
tsx tools/smoke/run.ts --env preprod --chain accounting --rpc <url>
```

## Output modes

| Flag | Effect |
|---|---|
| (default) | Full per-check table: key · expected · on-chain · status |
| `--summary` | One line per group: `▸ <group>  X/Y  ✓` |
| `--quiet` | Failures only |
| `--json` | Machine-readable; the full report is also written to `tools/smoke/output/` |

Other flags:

- `--strict` — warnings (e.g. `"TBD"` placeholders in config) become failures
- `--no-live-probes` — skip oracle / CCIP live calls (faster, less complete)

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed |
| `1` | One or more parity / topology failures |
| `2` | Incomplete deploy (predicted address has no code) |
| `3` | RPC error (connection / `429` / chain id mismatch) |
| `4` | Config error (invalid flags, missing RPC, missing config) |

## Architecture

```
tools/smoke/
├── run.ts                  CLI entrypoint
├── lib/
│   ├── checks/topology.ts  CREATE3 re-derivation, code.length, bytecode hash, ERC-1967 slots
│   ├── catalogue/
│   │   ├── getters.ts      GETTER_SPECS: one entry per JSONC leaf → on-chain getter
│   │   └── abis.ts         Hand-curated ABI fragments for the getters we call
│   ├── parity.ts           Generic engine: getter ↔ JSONC leaf via viem multicall
│   ├── create3.ts          Port of script/libraries/Create3AddressLib.sol
│   ├── artefact.ts         Load + index deployments/<env>/v1/<chain>.json
│   ├── bytecode.ts         forge inspect / out/ walker for deployed bytecode hashes
│   ├── format.ts           Humanise RAY → $, seconds → readable, bps → %, etc.
│   ├── render.ts           full / summary / quiet / json renderers
│   ├── report.ts           JSON report serialisation
│   ├── rpc.ts              viem public client + RPC URL resolution
│   └── types.ts            Shared types and exit-code constants
└── output/                 Per-run JSON reports (gitignored)
```

## Supply-chain policy

Smoke-harness direct deps follow two rules to bound exposure to compromised npm packages:

1. **Pinned exact versions** — no `^` or `~`. A lockfile + exact pin means `yarn install` cannot silently pick up a new version.
2. **Minimum age of 7 days** on the npm registry. A version published less than 7 days ago is rejected by the audit script. Freshly compromised packages are typically detected and yanked within hours; a 7-day floor avoids that window.

Audit on every lockfile change:

```sh
yarn smoke:audit-deps
```

Script: `tools/smoke/scripts/check-deps-age.ts`. Scope: the smoke-harness direct deps (`SMOKE_DIRECT_DEPS` constant — `viem`, `vitest`, `picocolors`, `cli-table3`). Transitive deps are governed by the lockfile + `resolutions`/`overrides` in `package.json` (e.g. `ws@8.20.1` is forced to clear CVE GHSA-58qx-3vcg-4xpx).

`yarn audit` and `npm audit` both pass with zero vulnerabilities at the time of writing.

## Adding coverage

A new parameter in `config/deployment-config.*.jsonc` is covered by adding one entry to `lib/catalogue/getters.ts`. The parity engine and renderer handle the rest. The catalogue is keyed by the same `ParameterSpec.key` as `tools/roles/lib/parameters-spec.ts`, so paired setters/getters stay in lockstep.

## Coverage

Catalogue size against the current preprod artefact (`tsx tools/smoke/scripts/dump-catalogue.ts preprod accounting`):

| Group | AC specs | EC specs |
|---|---:|---:|
| AccessManager (driven by `script/output/roles.json`) | 157 | 123 |
| AssetRegistry | 18 | 18 |
| WithdrawalExecutionPolicy | 6 | 6 |
| StableVault | 5 | — |
| Allocator | 4 | 6 |
| Oracles (PriceOracle + ChainBalanceOracle wiring) | 4 | 3 |
| BridgeAdapters | 3 | 3 |
| IouToken | 2 | — |
| **Total** | **199** | **159** |

Plus **live probes** (a separate group, batched into a single multicall):

- `PriceOracle.getPrice(asset) > 0` per asset
- `ChainBalanceOracle.getChainBalance(remoteChainId).isStale == false` (AC only)
- `CCIPRouter.isChainSupported(counterpartySelector) == true`
- L2 sequencer feed `latestRoundData().answer == 0` (AC, when `useMockSequencerUptimeFeed=false`)

`DepositPolicy`, `FundsBridgingPolicy`, and `SlippageCoverageVault` parity entries will appear automatically when a fresh deploy adds those contracts to the artefact — the catalogue is wired for them but skips when the artefact entry is missing.

The cross-reference immutables (`StableVault.ASSET_REGISTRY` etc., `internal immutable` with no public getter) are verified transitively via the topology bytecode-hash equivalence — the constructor args derive from CREATE3 (deterministic) and the runtime code embeds the immutables, so a matching `keccak256(actual.code) == keccak256(forge inspect deployedBytecode)` proves drift-free wiring.

## Deferred

- `--check-cross-chain` mode — verify AC and EC agree on shared invariants (delay tiers, profile addresses, `iouTokenName`, `priceOracleMinValidPriceRay`, peer `ccipSelector`).
- Optional functional smoke (`--with-functional`) — tiny deposit/withdraw/rebalance against a forked anvil.
