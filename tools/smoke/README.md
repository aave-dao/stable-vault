# tools/smoke — deployment smoke tests

A read-only sanity check that runs against a live RPC after a deploy. It compares every deployed contract — addresses, bytecode, configuration, role wiring, oracle health — against the source of truth in this repo (`config/deployment-config.<env>.jsonc`, `deployments/<env>/v1/<chain>.json`, and the role catalogue).

If anything drifted from what we shipped, it tells you exactly which value is wrong, on which contract, on which chain.

## What to use it for

Run this after every deploy or upgrade, on every environment, before you trust the system. It catches the kinds of mistakes a human can't easily catch by eyeballing diffs:

- Wrong contract address resolved by CREATE3.
- A constructor argument that doesn't match the JSONC.
- A role granted to the wrong profile, or with the wrong delay.
- A rate limit or cap that diverges from the configured value.
- An oracle wired to the wrong adapter, or an adapter reporting stale data.
- A bridge adapter not registered as it should be.
- Immutables that don't match the deployed bytecode hash.

It does **not** mutate state, send transactions, or require a private key. It only reads.

## Quick start

```sh
# After deploying preprod, run the harness on each chain.
yarn smoke:preprod:accounting
yarn smoke:preprod:earning

# Same for staging.
yarn smoke:staging:accounting
yarn smoke:staging:earning
```

Need a non-default RPC?

```sh
tsx tools/smoke/run.ts --env preprod --chain accounting --rpc <url>
```

Or via env var (one per env/chain):

```sh
SMOKE_RPC_PREPROD_ACCOUNTING=<url> yarn smoke:preprod:accounting
```

## Reading the output

By default you get a per-check table with the expected value and the on-chain value side by side, for every check (even passes). Switch view as needed:

| Flag | When to use |
|---|---|
| (default) | First time looking at a deployment, or when you want full evidence. |
| `--summary` | `▸ <group>  X/Y  ✓` — one line per group. Good for CI logs. |
| `--quiet` | Failures only. Good when running a known-good environment regularly. |
| `--json` | Machine-readable; the same report is also written to `tools/smoke/output/`. |

Other useful flags:

- `--strict` — turn warnings (e.g. `"TBD"` placeholders left in config) into failures. Use for prod.
- `--no-live-probes` — skip the oracle / CCIP live calls. Faster, less complete; use when the RPC is rate-limited or you only care about static state.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed. |
| `1` | One or more checks failed (parity, topology, live probe). Read the table to find which. |
| `2` | Incomplete deploy — a predicted CREATE3 address has no code. Finish the deploy and retry. |
| `3` | RPC problem — bad URL, `429`, or chain-id mismatch. |
| `4` | Config / CLI problem — bad flags, missing RPC, missing deployment artefact. |

## How it works (one paragraph)

The harness loads `config/deployment-config.<env>.jsonc` (the source of truth for configurable parameters) and `deployments/<env>/v1/<chain>.json` (the source of truth for which contracts were deployed and at what address). It then:

1. **Re-derives every CREATE3 address** from the deployer + salt and asserts the on-chain `code.length > 0` matches.
2. **Hashes the deployed bytecode** and compares against `forge inspect <contract> deployedBytecode`. This is what verifies the `internal immutable` wiring (e.g. `StableVault.ASSET_REGISTRY`) transitively, without needing a public getter.
3. **Batches one viem multicall** that reads every configured value via the contract's own getter, then compares it to the JSONC.
4. **Runs the AccessManager catalogue** driven by the canonical roles JSON (`.github/workflows/tooling/roles-sync/output/roles.json`). For every role: correct delay per env, correct profiles granted, correct selector wired to the right role on the right contract.
5. **Runs a few live probes** that don't fit the static catalogue: price oracle returns > 0, chain-balance oracle returns `isStale == false`, CCIP router supports the counterparty selector, L2 sequencer feed is up.

If a contract listed in the catalogue isn't in the deployment artefact (e.g. it hasn't been deployed yet on this chain), its checks are skipped — not failed.

## Adding a new check

Most additions are one line. If a new parameter shows up in `config/deployment-config.*.jsonc`, add one `GetterSpec` to `lib/catalogue/getters.ts` pointing at the contract's getter. The parity engine and renderer pick it up from there.

If a new contract shows up:
1. Make sure it's in the deployment artefact (the deploy script writes it).
2. Add its getters to `lib/catalogue/getters.ts` in a new `build<Contract>Specs` function.
3. If it has an ABI fragment you can't reuse, append it to `lib/catalogue/abis.ts`.

The catalogue keys match the same `ParameterSpec.key` used by `.github/workflows/tooling/roles-sync/lib/parameters-spec.ts`, so paired setters and getters stay in lockstep.

To peek at what the catalogue will produce against an environment without hitting the RPC:

```sh
tsx tools/smoke/scripts/dump-catalogue.ts preprod accounting
```

## Supply-chain policy

The harness pins exact versions (no `^` or `~`) and refuses to install any direct dependency published less than 7 days ago. Run the check on every lockfile change:

```sh
yarn smoke:audit-deps
```

The 7-day floor is the simplest defence against freshly-compromised npm packages — most malicious releases are detected and yanked within hours. The audit script enforces it for the harness's direct dependencies (`SMOKE_DIRECT_DEPS` in `tools/smoke/scripts/check-deps-age.ts`); transitive deps are governed by the lockfile and `resolutions` / `overrides` in `package.json`.

## File map

```
tools/smoke/
├── run.ts                  CLI entrypoint
├── lib/
│   ├── checks/topology.ts  CREATE3 re-derivation, code.length, bytecode hash, ERC-1967 slots
│   ├── checks/live-probes.ts
│   ├── catalogue/
│   │   ├── getters.ts      one entry per JSONC leaf → on-chain getter
│   │   ├── access-from-roles.ts   AccessManager checks driven by roles.json
│   │   └── abis.ts         hand-curated ABI fragments for the getters we call
│   ├── parity.ts           generic engine: getter ↔ JSONC leaf via viem multicall
│   ├── create3.ts          port of script/libraries/Create3AddressLib.sol
│   ├── artefact.ts         load + index deployments/<env>/v1/<chain>.json
│   ├── bytecode.ts         forge inspect / out/ walker for deployed bytecode hashes
│   ├── format.ts           humanise RAY → $, seconds → readable, bps → %, etc.
│   ├── render.ts           full / summary / quiet / json renderers
│   ├── report.ts           JSON report serialisation
│   ├── rpc.ts              viem public client + RPC URL resolution
│   └── types.ts            shared types and exit-code constants
├── scripts/
│   ├── dump-catalogue.ts   preview what the harness will check, no RPC needed
│   └── check-deps-age.ts   supply-chain audit (run on every lockfile change)
└── output/                 per-run JSON reports (gitignored)
```
