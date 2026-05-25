# Deployment Smoke Tests — Technical Specification

## Overview

A TypeScript + viem CLI under `tools/smoke/` that runs after a stable-vault deploy and proves the deployed system matches its configuration. Driven by a catalogue mirror of `tools/roles/lib/parameters-spec.ts`, it reads every on-chain value the JSONC config produces, compares to the source, and prints a terminal-friendly report that shows the actual on-chain values alongside the expected ones — even on pass. A dated JSON report is archived for the audit trail.

## Problem statement

PR 309 adds pre-deploy validations and bytecode-equivalence skip checks, but nothing reads the on-chain state *after* deploy and asserts it matches the JSONC config. Today a successful `forge script` exit means "the broadcast worked"; it does not mean "the system is configured how you intended it to be." Smoke tests close that gap and produce an auditable artefact the team can attach to a deploy PR or hand to an auditor.

## Proposed solution

Build `tools/smoke/` as a TypeScript CLI invoked via `tsx tools/smoke/run.ts --env preprod --chain accounting`. The harness loads three sources of truth (JSONC config, deployment artefact, on-chain state), runs five check phases (preflight → topology → parity → live probes → cross-chain), and emits both a pretty stdout report and a dated JSON report under `tools/smoke/output/`.

The load-bearing primitive is a generic parity engine driven by a getter catalogue that mirrors the setter catalogue at `tools/roles/lib/parameters-spec.ts`. Every JSONC leaf is paired with a contract + getter selector; the engine reads them all in parallel via viem `multicall`, compares to the JSONC values, and emits a structured `CheckResult` per leaf. Renderers turn `CheckResult[]` into either the full table, summary, JSON, or quiet output.

## Technical considerations

### Architecture impacts

- New top-level dir `tools/smoke/` mirroring the existing `tools/roles/` layout (ESM, strict TS, `.js` suffix on relative imports, Node 22 in CI). New `package.json` script entries `smoke:run`, `smoke:preprod`, `smoke:staging`, `smoke:prod`.
- Reuses `tools/roles/lib/parameters-spec.ts`, `parameters.ts` (for `loadDeploymentConfigs` + `getByPath`), `types.ts`, and `load-signatures.ts`. No code duplication of the catalogue.
- Adds viem (`viem@^2.51.0`), `picocolors@^1.1.1`, `cli-table3@^0.6.5`, `ora@^9.4.0`, `boxen@^8` to `package.json`. Pinned versions per framework-docs research.
- `tools/smoke/output/` is gitignored except for a `.gitkeep`. Matches the existing `script/output/` pattern.

### Performance implications

- ~150 reads against a single RPC. With viem `multicall3` batching tuned to `batchSize: 4096, wait: 16`, the parity phase completes in ~1.5s against an Arbitrum RPC and ~2s against mainnet. Total runtime target: under 5s for the full smoke including live probes.
- All multicalls pin to a single `blockNumber` captured at preflight to keep the run deterministic and dodge the "balance fresh at start, stale at end" failure mode.
- Live probes (`PriceOracle.getPrice`, `ChainBalanceOracle.getChainBalance`, `CCIPRouter.isChainSupported`) cannot be batched into the same multicall (they return non-uniform shapes), so they run in a parallel `Promise.allSettled` pass.

### Security considerations

- Smoke is read-only. No private keys, no broadcast.
- RPC URLs may be sensitive (Alchemy/Infura keys). The harness reads them from env vars (`SMOKE_RPC_<ENV>_<CHAIN>` or `--rpc <url>` override) and never logs the URL with secrets. The pattern follows `tools/roles/notion-sync.ts:48` style for `NOTION_API_KEY`.
- JSON reports include addresses + on-chain values but never RPC URLs or env-var contents. Reports are gitignored.

## Acceptance criteria

### Functional

- [ ] CLI invocation: `tsx tools/smoke/run.ts --env <preprod|staging|prod> --chain <accounting|earning>` runs the full smoke against the configured RPC and exits 0 on full pass.
- [ ] Output modes: default (full per-check view with on-chain values), `--summary`, `--quiet`, `--json`. All four produce well-formed output.
- [ ] **Output shows the present on-chain value next to the expected value on every check, even on pass** — this is the explicit requirement.
- [ ] All 11 check groups from the interview scope run: Topology, AccessManager, AssetRegistry, Allocator, StableVault, WithdrawalExecutionPolicy, DepositPolicy, FundsBridgingPolicy, SlippageCoverageVault, Oracles, BridgeAdapters, IouTokenManager.
- [ ] CREATE3 re-derivation from `Create3AddressBook` salt seeds matches addresses in `deployments/<env>/<v>/<chain>.json` exactly. Divergence reported as a topology failure.
- [ ] Bytecode-equivalence check: for every deployed contract, `keccak256(actual.code) == keccak256(forge inspect <name> deployedBytecode)`. Mismatch reported with `expected/actual` runtime-code hashes.
- [ ] Transparent proxies (Allocator, AssetRegistry, IouTokenManager, PriceOracle, WithdrawalExecutionPolicy, FundsBridgingPolicy) have their ERC-1967 impl + admin slots read and validated against the implementation entries recorded in the artefact.
- [ ] AccessManager checks: every role grant delay from JSONC matches `getRoleGrantDelay(roleId)`; every profile address matches `getRoleMember(roleId, 0)` (or equivalent); deployer's ADMIN_ROLE is revoked.
- [ ] Per-asset parity: for each asset in `{gho, usdc, usdt}`, parity engine reads back trusted/distrusted flags, deposit policy caps, bridging policy caps, SCV caps. Output table groups per-asset.
- [ ] Per-bridge-adapter parity: for each registered `(asset, destChainId, bridgeAdapter)` triple, the whitelist state is verified.
- [ ] Conditional contracts (AdiAdapter): three-state check — absent / deployed-not-registered / deployed-and-registered. Skipped cleanly when `crossChainController == address(0) && registerOnGateway == false`.
- [ ] Conditional feeds (`useMockBundleFeed`, `useMockSequencerUptimeFeed`): when `true`, smoke verifies the configured mock address, not a live Chainlink feed.
- [ ] TBD/placeholder detection: zero addresses, `"TBD"` strings, and any JSON value matching a sentinel pattern produce a **warning** by default (not a failure). `--strict` flag promotes warnings to failures.
- [ ] Live probes: `PriceOracle.getPrice(asset) > 0` for each asset; `ChainBalanceOracle.getChainBalance(chainId).isStale == false`; `CCIPRouter.isChainSupported(counterpartySelector) == true`; L2 sequencer feed reports up (when applicable).
- [ ] JSON report: written to `tools/smoke/output/<env>-<chain>-<ISO8601>.json` on every run. Schema includes `meta` (commit, chain, env, RPC chainId, blockNumber, timestamp, jsonc-config SHA, deployment-artefact SHA), `groups[]`, `summary` (counts), `warnings[]`, `errors[]`.
- [ ] Exit codes: `0` pass; `1` parity/topology failure; `2` incomplete deploy (predicted addresses with no code); `3` RPC error / partial failure; `4` config error (TBD without `--allow-warnings`).

### Non-functional

- [ ] Full run completes in under 5s on a healthy RPC.
- [ ] Runs deterministically against a pinned `blockNumber` (captured at preflight).
- [ ] Output uses Unicode box-drawing chars (`╔═║╚`) and check marks (`✓`/`✗`) but no emojis. Matches the global CLAUDE.md style rule.
- [ ] No new toolchain dependencies beyond TS deps already present (tsx, typescript) plus a small set of well-maintained CLI libs.
- [ ] CI integration: a new job in `.github/workflows/test.yml` (or a new workflow) runs `tsx tools/smoke/run.ts --env preprod --chain <both>` against a forked `anvil` instance pinned to a `--fork-block-number`. Operator-mode (live RPC) is available as a yarn script.

## Implementation

### Directory layout

```
tools/smoke/
├── run.ts                     # CLI entrypoint
├── package.json               # Local "type": "module" so ora@9 (ESM-only) loads
├── tsconfig.json              # Extends tools/roles/tsconfig.json
├── lib/
│   ├── checks/
│   │   ├── topology.ts        # CREATE3 re-derivation, code.length, ERC-1967, bytecode hash
│   │   ├── access.ts          # role delays, profile grants, deployer revocation
│   │   ├── policies.ts        # generic parity over GETTER_SPECS (DepositPolicy/Bridging/SCV/WEP)
│   │   ├── registries.ts      # AssetRegistry, Allocator (strategies, trust flags)
│   │   ├── oracles.ts         # PriceOracle + ChainBalanceOracle adapter wiring + live probes
│   │   └── bridges.ts         # CCIP / a.DI adapter whitelist + live isChainSupported
│   ├── catalogue/
│   │   ├── getters.ts         # GETTER_SPECS: one entry per ParameterSpec.key (mirrors setters)
│   │   └── topology-spec.ts   # contract name → expected proxy/runtime check
│   ├── parity.ts              # Generic engine: read getter → decode → compare to JSONC leaf
│   ├── render.ts              # Renderers: full | summary | quiet | json
│   ├── format.ts              # Humanise: RAY → $, seconds → readable, bps → %, etc.
│   ├── create3.ts             # CREATE3 address derivation (port of Create3AddressLib.sol)
│   ├── rpc.ts                 # viem public client per env/chain + RPC URL resolution
│   ├── artefact.ts            # Load + index deployments/<env>/v1/<chain>.json
│   ├── bytecode.ts            # forge inspect <name> deployedBytecode runner
│   └── report.ts              # JSON report serialisation
└── output/
    └── .gitkeep
```

### Parity engine (the load-bearing piece)

```ts
// tools/smoke/lib/parity.ts (sketch)
import { PARAMETER_SPECS } from "../../roles/lib/parameters-spec.js";
import { GETTER_SPECS } from "./catalogue/getters.js";
import { loadDeploymentConfigs, getByPath } from "../../roles/lib/parameters.js";

export type CheckResult =
  | { kind: "pass"; key: string; expected: bigint | string | boolean; actual: bigint | string | boolean }
  | { kind: "fail"; key: string; expected: ...; actual: ...; reason: string }
  | { kind: "skipped"; key: string; reason: string }
  | { kind: "warning"; key: string; expected: ...; actual: ...; note: string };

export async function runParity(
  env: Env,
  chain: ChainKind,
  client: PublicClient,
  blockNumber: bigint,
  artefact: DeploymentArtefact,
): Promise<CheckResult[]> {
  const config = loadDeploymentConfigs(REPO_ROOT)[env];
  const calls = buildMulticallCalls(PARAMETER_SPECS, GETTER_SPECS, config, artefact);
  const results = await client.multicall({ contracts: calls, blockNumber, allowFailure: true });
  return zip(calls, results).map((c, r) => compareLeaf(c.spec, c.jsonValue, r));
}
```

`GETTER_SPECS` is a `Map<string, GetterSpec>` keyed by `ParameterSpec.key`. Each entry carries the getter's ABI fragment, the args extractor (from `ValueSpec.path` + asset key when per-asset), and a decoder. Adding a new parameter to `parameters-spec.ts` requires a matching entry here.

### Topology check

```ts
// tools/smoke/lib/checks/topology.ts (sketch)
export async function runTopology(
  env: Env, chain: ChainKind, client: PublicClient, blockNumber: bigint, artefact: DeploymentArtefact,
): Promise<CheckResult[]> {
  const results: CheckResult[] = [];
  for (const [name, entry] of Object.entries(artefact)) {
    // 1. CREATE3 re-derivation
    if (entry.saltSeed) {
      const predicted = computeCreate3Address(deployer, entry.saltSeed);
      if (predicted.toLowerCase() !== entry.address.toLowerCase()) {
        results.push({ kind: "fail", key: `topology.${name}.create3`, expected: predicted, actual: entry.address, reason: "address-mismatch" });
        continue;
      }
    }
    // 2. code.length
    const code = await client.getBytecode({ address: entry.address, blockNumber });
    if (!code || code === "0x") {
      results.push({ kind: "fail", key: `topology.${name}.code`, expected: ">0 bytes", actual: "0 bytes", reason: "not-deployed" });
      continue;
    }
    // 3. Bytecode-hash equivalence
    const expectedRuntime = await forgeInspectDeployedBytecode(name);
    if (keccak256(code) !== keccak256(expectedRuntime)) {
      results.push({ kind: "fail", key: `topology.${name}.bytecode`, expected: keccak256(expectedRuntime), actual: keccak256(code), reason: "bytecode-mismatch" });
      continue;
    }
    // 4. ERC-1967 slots (transparent proxies only)
    if (TRANSPARENT_PROXIES.has(name)) {
      const impl = await client.getStorageAt({ address: entry.address, slot: ERC1967_IMPL_SLOT, blockNumber });
      const admin = await client.getStorageAt({ address: entry.address, slot: ERC1967_ADMIN_SLOT, blockNumber });
      // assert impl matches `<name>::Implementation` entry in artefact
      // assert admin is the expected ProxyAdmin or zero per design
    }
    results.push({ kind: "pass", key: `topology.${name}`, expected: entry.address, actual: entry.address });
  }
  return results;
}
```

### CREATE3 address derivation

Port `script/libraries/Create3AddressLib.sol:8-66` to TS:

```ts
// tools/smoke/lib/create3.ts (sketch)
const CREATEX_FACTORY = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed";
const DEPLOYER_ZEROING_MASK = 0xfffffffffffffffffffffffffffffffffffffffffffffffeffffffffffffffffn;
const CROSS_CHAIN_PROTECTION_MASK = ...; // copy from Create3AddressLib

export function computeCreate3Address(deployer: Address, seed: string): Address {
  const seedHash = keccak256(toBytes(seed));
  const salt = (BigInt(seedHash) & DEPLOYER_ZEROING_MASK & CROSS_CHAIN_PROTECTION_MASK) | (BigInt(deployer) << 96n);
  const derivedSalt = keccak256(encodePacked(["address", "bytes32"], [deployer, padHex(toHex(salt), 32)]));
  // Then standard CREATE address from CREATEX_FACTORY with derivedSalt as nonce-equivalent
  ...
}
```

### Rendering (with the explicit "show present values" requirement)

```ts
// tools/smoke/lib/render.ts (sketch)
export function renderFull(results: CheckResult[], meta: RunMeta): string {
  const out: string[] = [renderBanner(meta)];
  const grouped = groupByPrefix(results); // e.g. "topology.*", "policies.depositPolicy.*"
  for (const [groupName, checks] of grouped) {
    out.push(picocolors.bold(`▸ ${groupName}`));
    const table = new Table({
      head: ["", "key", "expected", "on-chain", ""],
      style: { head: ["dim"], border: ["dim"] },
      colAligns: ["center", "left", "right", "right", "left"],
    });
    for (const c of checks) {
      table.push([
        c.kind === "pass" ? picocolors.green("✓") : picocolors.red("✗"),
        c.key,
        humanise(c.expected, c.format),
        humanise(c.actual, c.format),
        c.kind === "pass" ? "" : picocolors.red(c.reason ?? ""),
      ]);
    }
    out.push(table.toString());
  }
  out.push(renderSummary(results));
  return out.join("\n");
}
```

Compact mode (`--summary`) replaces the per-check table with one line per group: `▸ <group> 14 / 14 ✓`. Quiet mode (`--quiet`) suppresses pass rows. JSON mode (`--json`) skips rendering entirely and dumps `report.toJson()`.

### CLI argument shape

```
tsx tools/smoke/run.ts \
  --env <preprod|staging|prod>    # required
  --chain <accounting|earning>     # required
  [--rpc <url>]                    # override default from env
  [--summary]                      # compact view
  [--quiet]                        # failures only
  [--json]                         # machine-readable
  [--strict]                       # warnings → failures
  [--no-live-probes]               # skip oracle / CCIP live calls
  [--fail-fast]                    # exit on first failure
  [--check-cross-chain]            # v2: run both chains, verify shared invariants
```

### Yarn scripts (add to root `package.json`)

```json
"smoke:run":      "tsx tools/smoke/run.ts",
"smoke:preprod":  "tsx tools/smoke/run.ts --env preprod",
"smoke:staging":  "tsx tools/smoke/run.ts --env staging",
"smoke:prod":     "tsx tools/smoke/run.ts --env prod"
```

### Makefile target

```make
smoke :; tsx tools/smoke/run.ts --env $(ENV) --chain $(CHAIN)
```

Invocation: `make smoke ENV=preprod CHAIN=accounting`.

## Order of operations

1. **Preflight** (no RPC): parse args, load JSONC config, scan for TBD placeholders, load deployment artefact, capture commit + file SHAs.
2. **RPC handshake**: capture current block number, chain id; assert chain id matches JSONC `<chain>Chain.chainId`.
3. **Topology** (pinned block): CREATE3 re-derivation → code.length → bytecode-hash equivalence → ERC-1967 slots.
4. **Parity** (pinned block, parallel multicall): catalogue-driven reads + comparisons.
5. **Live probes** (parallel, current block): `PriceOracle.getPrice`, `ChainBalanceOracle.getChainBalance`, `CCIPRouter.isChainSupported`, L2 sequencer feed.
6. **Cross-chain** (optional, `--check-cross-chain`): run steps 1-5 against both AC and EC; additionally verify shared invariants (`iouTokenName`, `priceOracleMinValidPriceRay`, delay tiers, `profiles.*`, peer `ccipSelector`).
7. **Render** + **report**: stdout + JSON.

## Cross-reference immutables — v1 decision

Three contracts (`StableVault`, `Allocator`, `FundsHandler`) declare cross-reference immutables (`ASSET_REGISTRY`, `IOU_TOKEN_MANAGER`, etc.) as `internal immutable` with no public getters. The deploy script wires them via constructor args from CREATE3-derived addresses.

**v1 approach: rely on the topology bytecode-hash equivalence as transitive proof.** The argument: (a) constructor args derive from CREATE3, which is deterministic from `(deployer, saltSeed)`; (b) runtime bytecode embeds the constructor-set immutables; (c) if `keccak256(actual.code) == keccak256(forge inspect deployedBytecode)` holds, the immutables match by construction. Adding public getters is deferred — surface as a follow-up question to the team. See specflow-analysis M3.

## Success metrics

- All 11 check groups pass against the latest preprod deploy.
- Smoke runs in under 5s end-to-end on a healthy RPC.
- A breaking JSONC change (e.g. flipping `defaultFeeBps`) is caught by smoke against an un-redeployed system, with a clear diff in the output.
- Operator confidence — the team uses `make smoke` as the canonical step between deploy and "this is live."

## Dependencies & risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| viem multicall batch sizing wrong for Arbitrum | Medium | Low | Tune `batchSize` to 4096, measure under load, fall back to `Promise.all` chunking if needed |
| `forge inspect deployedBytecode` is slow / flaky | Low | Medium | Cache results in-memory per run; CI step pre-runs `forge build` so artefacts are warm |
| RPC 429 mid-run | Medium | Medium | Distinct exit code 3; surface as actionable error not as parity fail; CI retries the smoke job 2x before failing |
| Per-asset parity catalogue drifts behind new assets added to config | High | Low | The catalogue is keyed by `parameters-spec.ts` entries; adding an asset means extending one file; CI fails on any catalogue gap |
| ERC-1967 slot reads return zero for non-proxies | Low | Low | Topology pre-filter: only proxies in `TRANSPARENT_PROXIES` set get slot reads |
| Cross-reference immutables drift undetected | Medium | Medium | Bytecode-hash equivalence (see v1 decision above) catches any constructor-arg drift |

## Out of scope for v1

- Functional smoke (`--with-functional`): tiny deposit / requestWithdrawal / executeWithdrawal / rebalance against a forked anvil. Deferred.
- Cross-chain mode (`--check-cross-chain`): v2.
- Notion DB sync of smoke results. Deferred.
- Multi-deploy diff (smoke now vs. smoke last week, show me what changed). Deferred.

## References & research

### Internal
- `tools/roles/` — pattern to mirror
- `tools/roles/lib/parameters-spec.ts:50-887` — catalogue to extend
- `tools/roles/lib/parameters.ts:33-244` — JSONC loader + leaf accessor
- `tools/roles/lib/load-signatures.ts` — selector resolution
- `script/base/BaseChainDeployment.sol:256-272` — deployment artefact schema
- `script/base/Create3AddressBook.sol:12-41` — salt seed inventory
- `script/libraries/Create3AddressLib.sol:8-66` — CREATE3 algorithm to port
- `deployments/preprod/v1/{accounting,earning}.json` — real artefacts
- `config/deployment-config.preprod.jsonc` — config schema reference
- `.github/workflows/roles-sync.yml` — CI workflow template

### External
- viem v2 multicall docs — https://viem.sh/docs/contract/multicall
- viem `getBytecode` / `getStorageAt` — https://viem.sh/docs/contract/getBytecode + https://viem.sh/docs/contract/getStorageAt
- `jsonc-parser` — https://www.npmjs.com/package/jsonc-parser
- Aave `ProtocolV3TestBase` (snapshot-before / snapshot-after / JSON diff) — https://github.com/bgd-labs/aave-helpers
- Optimism `op-validator` (on-chain validator + off-chain CLI table) — https://github.com/ethereum-optimism/optimism
- Compound scenario configs — https://github.com/compound-finance/comet/tree/main/scenario

### Research artefacts
- `research/repo-analysis.md` — repo conventions, tools/roles patterns, deployment artefact schema
- `research/best-practices.md` — prior art (Aave, Optimism, Compound), viem batching, CLI library recommendations
- `research/framework-docs.md` — viem, tsx, jsonc-parser, picocolors, cli-table3, ora pinned versions and gotchas
- `research/specflow-analysis.md` — missing flows, must-fix list, exit-code policy, decisions still open
