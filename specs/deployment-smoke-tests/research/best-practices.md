# Deployment smoke tests: external best practices

Research compiled 2026-05-25 for a multi-contract upgradeable system on Arbitrum (accounting) + Ethereum L1 (earning) with CCIP and a.DI cross-chain bridging.

---

## 1. Industry patterns: post-deploy smoke tests on multi-contract EVM systems

### Aave (most relevant prior art for this codebase)

**`bgd-labs/aave-helpers` — `ProtocolV3TestBase`**

- Repo: https://github.com/bgd-labs/aave-helpers
- Contract: https://github.com/bgd-labs/aave-helpers/blob/main/src/ProtocolV3TestBase.sol
- Entry point: `defaultTest()` — orchestrates the full suite: config snapshot before, execute proposal, config snapshot after, diff, plausibility checks, e2e per asset.
- Output convention: `./reports/{reportName}_before.json` and `./reports/{reportName}_after.json`. JSON shape: `{ "raw": <state diff>, "logs": <recorded logs> }`. Diffs are written via `vm.writeJson(rawDiff, filePath, jsonPath)`.
- Specific methods to model: `configChangePlausibilityTest()`, `_validateNoExecutorStorageChange()`, `e2eTestAsset()`, `diffReports()`, `generateSeatbeltReport()`.
- Pattern: pre-snapshot -> simulate execution on fork -> post-snapshot -> diff -> assert only the expected fields changed.

**`bgd-labs/aave-cli`**

- Repo: https://github.com/bgd-labs/aave-cli
- TypeScript CLI. Key command: `aave-cli diff <from> <to>` — produces a human-readable markdown report from two JSON snapshots.
- Also: `aave-cli ipfs <source>` (BS58 hash), `aave-cli governance view`, `aave-cli governance getStorageRoots`, `aave-cli governance getVotingProofs`.
- Companion JS package `@aave-dao/aave-helpers-js` exposes `aave-helpers-js diff-snapshots before.json after.json -o diff.md` — markdown diff for pool configs.

**`aave-dao/aave-proposals-v3`**

- Repo: https://github.com/aave-dao/aave-proposals-v3
- Generates `.sol` (payload), `.t.sol` (tests), `.s.sol` (deploy script), `.md` (AIP doc), `config.ts` per proposal.
- Payloads inherit `AaveV3PayloadEthereum`, `AaveV3PayloadArbitrum`, etc., which standardise the post-execute hooks. Tests inherit `ProtocolV3TestBase` and call `defaultTest()`.

**`aave-dao/aave-delivery-infrastructure`**

- Repo: https://github.com/aave-dao/aave-delivery-infrastructure
- a.DI cross-chain test suite lives under `tests/`. Certora formal verification properties under `security/`. Deploy + maintenance scripts under `scripts/`. Note: external repo doesn't expose a documented one-shot "post-deploy smoke" tool — validation happens via the Forge test suite running against the fork.

### Optimism

**`op-validator`**

- Docs: https://docs.optimism.io/operators/chain-operators/tools/op-validator
- CLI: `op-validator validate v2.0.0 --l1-rpc-url <url> --absolute-prestate <hex> --proxy-admin <addr> --system-config <addr> --l2-chain-id <id> --fail`
- Calls on-chain `StandardValidatorV180` / `StandardValidatorV200` contracts that return error codes. Output is a table: ERROR code (e.g. `PDDG-40`) | DESCRIPTION. Exits non-zero with `--fail` on findings. This is the closest off-the-shelf reference for "check deployment against expected config".
- Checks: implementations + versions, proxy configs, system params, cross-component relationships.

**`ethereum-optimism/superchain-ops`**

- Repo: https://github.com/ethereum-optimism/superchain-ops
- Two-doc convention per task: `README.md` (what + why) and `VALIDATION.md` (expected domain hash + message hash + state changes).
- Commands: `just simulate-stack <network> <task>` prints state changes side-by-side with Tenderly. `just list-stack` enumerates the task chain. `SKIP_DECODE_AND_PRINT=1` skips markdown for speed.
- Pattern worth stealing: VALIDATION.md as a versioned, signed, human-readable "this is what should change" document committed alongside the task.

### Compound

**Comet scenario runner**

- Doc: https://github.com/compound-finance/comet/blob/main/SCENARIO.md
- Scenarios are TS files in `scenario/` using a declarative `scenario('name', { upgrade: true }, async ({ comet, actors }) => { ... })` API.
- Run with `npx hardhat scenario --bases development,sepolia,fuji --workers 4`.
- `upgrade: true` constraint forces a fresh deploy + proxy upgrade per scenario so the same scenario runs against every network.
- Deployments live at `deployments/<network>/<base>/` with `deploy.ts` + `configuration.json`. Pattern worth stealing: per-network config JSON next to deploy script, scenarios run against all of them.

### Safe

- Repo: https://github.com/safe-global/safe-smart-account, `package.json` scripts.
- Pipeline: `npx hardhat <network> deploy`, then `sourcify`, then `etherscan-verify`, then `local-verify`.
- `local-verify` recompiles contracts from artifacts and compares bytecode to onchain code. This is the bytecode-parity check.
- Deterministic addresses across networks via the `safe-deployments` JSON catalogue: https://github.com/safe-global/safe-deployments

### Maker / Sky

- Pattern: spell tests run on a forked mainnet with the deployed spell address pinned. Verify (a) contract verified on Etherscan, (b) constructor / schedule / cast match the template, (c) execute logic matches the proposal text.
- Reference: https://community-development.makerdao.com/governance/executive-audit

### Morpho

- Repo: https://github.com/morpho-org/morpho-blue-deployment
- After each `yarn deploy:<component> <network> --broadcast`, the deploy script appends a verify command to a per-component shell script (e.g. `script/morpho/verify.sh`). Verification is etherscan source verification, not state parity.

### Lido

- Approach: deployment scripts read/write `deployed-<network>.json` between steps as a state file (e.g. LidoTemplate address, implementation addresses, NodeOperatorsRegistry).
- Acceptance tests run after the deploy to validate bridge params.
- L2 repo: https://github.com/lidofinance/lido-l2

### Uniswap / Curve

- Both rely on Foundry / Brownie test suites against forks rather than a separate smoke-test CLI. Uniswap V4 template (`uniswapfoundation/v4-template`) keeps deploy + interaction scripts in `script/` and verifies via post-deploy reads.

### Takeaway pattern

Three converging conventions:

1. **Snapshot + diff** (Aave): JSON before / JSON after / generated markdown diff.
2. **Validator contract** (Optimism): on-chain contract returns error codes, off-chain CLI formats them.
3. **Scenarios** (Compound): declarative TS scenarios run against per-network config.

For your use case (multi-contract upgradeable, catalogue-driven, cross-chain), the **snapshot + diff + per-network config JSON** pattern from Aave + Compound is the closest match. The op-validator "tabular error codes" output style is the right model for the CLI surface.

---

## 2. Config-to-on-chain parity tools

**Short answer: no generic, catalogue-driven parity engine exists as a published library.** Everything in production is bespoke per protocol.

### Closest off-the-shelf options

- **`forge inspect <contract> storageLayout`** — emits storage layout JSON. Combined with `cast storage <addr> <slot>` you can build slot-by-slot parity, but it's manual.
- **`Rubilmax/foundry-storage-check`** (https://github.com/Rubilmax/foundry-storage-check) — GitHub Action. Generates storage layout via `forge inspect`, diffs against previous artifact, optionally queries an RPC to confirm newly added slots are zero on-chain. Detects type changes, removals, naming differences. Sample config:
  ```yaml
  - uses: Rubilmax/foundry-storage-check@v3.8
    with:
      contract: src/Contract.sol:Contract
      rpcUrl: wss://eth-mainnet.g.alchemy.com/v2/<KEY>
      address: 0x...
      failOnRemoval: true
  ```
  This checks *upgrade safety*, not *config parity*.
- **`@dethcrypto/eth-sdk`** (https://github.com/dethcrypto/eth-sdk) — generates type-safe ethers contract clients from `eth-sdk/config.ts` listing addresses. Auto-resolves proxy implementations via Etherscan. Doesn't do parity itself but gives you a typed client to write parity against. (gnosisguild fork: https://github.com/gnosisguild/eth-sdk)
- **OpenZeppelin Upgrades Plugin** — checks storage compatibility on `prepareUpgrade`. Hardhat + Foundry variants exist.

### Hardhat patterns

- `hardhat-deploy` (https://github.com/wighawag/hardhat-deploy) has lifecycle hooks (`beforeDeploy`, `afterDeploy`) where you can call view functions and assert. No standard library for this; everyone rolls their own.
- Hardhat Ignition has `--verify` for *source* verification, not state parity.

### Conclusion

If you build a catalogue-driven parity engine, it's a publishable contribution. The closest published prior art is `aave-helpers`' snapshot-diff approach, but it's Aave-specific (knows about reserves, eModes, rate strategies).

---

## 3. Terminal output libraries (Node.js / TypeScript)

### Colors

- **`picocolors`** (https://github.com/alexeyraspopov/picocolors) — 7 KB unpacked, 1.9 KB gzipped, zero deps. ~14x smaller than chalk, ~2x faster on simple styles. Load time ~0.466 ms vs chalk's ~6.167 ms. Used by Tailwind, Vite, Prettier internals. **Default choice for a smoke-test CLI.**
- **`chalk`** v5 — 101 KB unpacked, 13 KB gzipped. Richer API (tagged templates, nested styles), ESM-only. Reach for it only if you want `chalk.red.bold\`text\`` template literals.
- **`ansis`** — fastest when applying multiple stacked styles (red + bgWhite). Tiny too. Worth knowing about: https://bestofjs.org/projects/ansis
- **`node:util` `styleText`** — native since Node 20.12 / 21.7. No dependency. Respects `NO_COLOR`, `NODE_DISABLE_COLORS`, `FORCE_COLOR`. Pattern:
  ```ts
  import { styleText } from 'node:util';
  console.log(styleText('red', 'fail'));
  console.log(styleText(['bold', 'green'], 'ok'));
  ```
  If your Node target is >= 20.12 and you only need basic colors, this avoids a dep entirely. Reference: https://nodejs.org/en/blog/migrations/chalk-to-styletext

### Tables

- **`cli-table3`** (https://www.npmjs.com/package/cli-table3) — API-compatible drop-in for the unmaintained `cli-table` / `cli-table2`. Supports col/row span, per-cell styles, word wrap, vertical alignment, proper ANSI-color-aware truncation. Optional `ansis` dep for color. **Default choice.**
- **`cli-table`** — unmaintained. Avoid.
- **`console-table-printer`** (https://github.com/ayonious/console-table-printer) — simpler API, built-in color types (`COLOR`, `ALIGNMENT`), good TS support, less flexible than cli-table3. Good for plain status tables with row colors.
- **`table`** (Sindre Sorhus) — widely used, more verbose API, strong on borders. Heavier than cli-table3.

For dense parity output (Asset | Field | Config | On-chain | Status), `cli-table3` with per-cell color and word-wrap is the strongest fit.

### Spinners and banners

- **`ora`** v9 (https://github.com/sindresorhus/ora) — de facto standard. ESM-only since v6. Strong TS types. Works with async/await, supports `succeed`, `fail`, `warn`, `info`. Pattern:
  ```ts
  const spinner = ora('Fetching on-chain state').start();
  // ...
  spinner.succeed('Fetched 142 values');
  ```
- **`boxen`** v8 (https://github.com/sindresorhus/boxen) — banners with borders. ESM-only. Useful for the header banner of a smoke-test CLI.
- **`cli-spinners`** — spinner frame collection, consumed via `ora`.

### Other libraries worth knowing

- **`log-symbols`** — unicode `✔`, `✖`, `⚠`, `ℹ` with colors. Pairs with picocolors.
- **`figures`** — cross-platform unicode symbols (degrades to ASCII on Windows).
- **`update-notifier`** — version drift warnings, useful if the smoke-test CLI ships as a published package.
- **`commander`** or **`cac`** — argument parsing. cac is lighter.
- **`enquirer`** — interactive prompts if you need confirm-before-run flows.
- **`ink`** — React-for-CLIs. Overkill for a smoke-test CLI but listed for completeness.

### Recommended stack for this CLI

```
picocolors          # colors (or node:util styleText if Node >= 20.12)
cli-table3          # parity tables
ora                 # progress for slow RPC stages
boxen               # opening banner with chain / block / network
log-symbols         # status glyphs
cac or commander    # CLI args
```

Total install footprint: ~30 KB gzipped, all maintained, all ESM-compatible.

---

## 4. viem patterns for batch read-only RPC

### Default approach: `publicClient.multicall`

Docs: https://viem.sh/docs/contract/multicall

```ts
const results = await publicClient.multicall({
  contracts: [
    { address, abi, functionName: 'foo', args: [...] },
    // ...
  ],
  allowFailure: true,   // default true; returns { status, data } per call
  batchSize: 1024,      // bytes per multicall chunk; 0 disables chunking
  blockNumber: 12345n,  // optional: pin to block for snapshot consistency
  deployless: false,    // if true, deploys multicall via state override (use on chains without Multicall3)
  multicallAddress: '0xca11bde05977b3631167028862be2a173976ca11', // override per chain
  stateOverride: [...], // optional ephemeral state for what-if reads
});
```

Return shape with `allowFailure: true`:
```ts
({ status: 'success'; data: TReturn } | { status: 'reverted'; error: string })[]
```
With `allowFailure: false`, a plain array of return values. Throw on first revert.

### Default-on aggregation via client config

Docs: https://viem.sh/docs/clients/public

```ts
const publicClient = createPublicClient({
  chain: arbitrum,
  transport: http(rpcUrl),
  batch: {
    multicall: {
      wait: 16,         // ms to wait before flushing
      batchSize: 512,   // bytes per chunk (smaller than the 1024 default is safer on rate-limited RPCs)
      deployless: true,
    },
  },
});
```

With this enabled, every `publicClient.readContract` call is auto-batched into a single `eth_call` per batch window. No code change in callers. Best for a parity engine where dozens of small reads fire from different code paths.

### Best practice for 100+ values without rate limiting

Alchemy guidance (https://www.alchemy.com/docs/reference/batch-requests):
- HTTP batch hard limit: 1000 requests; reliability degrades well before that.
- WebSocket batch hard limit: 20.
- Recommended: **under 50 requests per batch**, send batches concurrently rather than one giant batch.
- Rate-limit response: HTTP 429 with `"Your app has exceeded its compute units per second capacity"`.

Concrete pattern for 100+ values:

1. Use `publicClient.multicall` with `batchSize` set so chunks stay under ~50 calls or ~32 KB calldata, whichever hits first.
2. Pin every call to the same `blockNumber` so the result is a coherent snapshot (otherwise reorg / reordering can show different state across calls).
3. Use `allowFailure: true` so one reverting view function doesn't kill the whole report.
4. If using `batch.multicall` on the client, set `wait` to 16-32 ms to let callsites accumulate before flushing.
5. For very large catalogues (500+), split by chain or by domain (assets vs roles vs bridges) and run concurrent `Promise.all` over independent multicalls.

Also useful: https://github.com/alessandroaw/viem-multicall-group — a viem wrapper that manages multiple multicall contexts. Likely overkill if you control your own batching.

### Gotchas

- Multicall3 doesn't exist on every chain. Deployments listed at https://github.com/mds1/multicall. For Arbitrum + Ethereum mainnet you're fine; for niche L2s use `deployless: true` (state-override deploy) or fall back to per-call reads.
- `getStorageAt` (e.g. ERC-1967 implementation slot reads) is **not** batchable through `multicall` — it's an `eth_getStorageAt` not `eth_call`. Use `Promise.all` with a concurrency limiter.
- WebSocket transport gives free batching but 20-request hard cap. For 100+ values prefer HTTP + explicit multicall.

---

## 5. CI integration: forked node in GitHub Actions

### Three viable patterns

**Pattern A: `anvil --fork-url` as a service**

```yaml
jobs:
  smoke:
    runs-on: ubuntu-latest
    services:
      anvil:
        image: ghcr.io/foundry-rs/foundry:latest
        ports:
          - 8545:8545
        env:
          ANVIL_IP_ADDR: 0.0.0.0
    steps:
      - run: anvil --fork-url ${{ secrets.MAINNET_RPC_URL }} --port 8545 &
      # or run anvil in a regular step rather than as a service
```

Pitfalls (https://github.com/foundry-rs/foundry/issues/7631):
- Cold-start latency in CI on a fresh image (Foundry binary download + initial fork sync).
- Docker image `services:` block can't pass entrypoint args; use `ANVIL_IP_ADDR=0.0.0.0` env var instead of `--host`.
- For multi-chain (Ethereum + Arbitrum) you need two anvils on different ports.

**Pattern B: Foundry directly with `--rpc-url` (no local anvil)**

```yaml
- uses: foundry-rs/foundry-toolchain@v1
- run: forge test --fork-url ${{ secrets.ARB_RPC_URL }} --fork-block-number 12345678
```

Simpler. Foundry creates an internal in-process fork. No port management. Best when your smoke tests are Forge tests, not a Node CLI.

**Pattern C: Tenderly Virtual TestNets**

- Action: https://github.com/Tenderly/vnet-github-action
- Provisions ephemeral VNets per CI run, supports forking multiple chains in parallel, exposes RPC via env vars (`TENDERLY_PUBLIC_RPC_URL_{chainId}`).
- Sample:
  ```yaml
  - uses: Tenderly/vnet-github-action@v1.0.x
    with:
      mode: CI
      access_key: ${{ secrets.TENDERLY_ACCESS_KEY }}
      project_name: ${{ vars.TENDERLY_PROJECT_NAME }}
      account_name: ${{ vars.TENDERLY_ACCOUNT_NAME }}
      testnet_name: 'CI smoke test'
      network_id: |
        1
        42161
      chain_id_prefix: 7357
      state_sync: true
  ```
- Trade-offs: needs Tenderly subscription, gives you a hosted explorer + debugger so failures are inspectable post-mortem, supports cross-chain test scenarios in one run, accepts unlimited faucet topping.

### Recommended choice

For a TS CLI running against Arbitrum + Ethereum with CCIP/a.DI:
- **Read-only parity checks**: Pattern B (forge or viem against the live RPC at a pinned block) is simplest. No fork needed if you're not mutating state.
- **End-to-end simulations** (e.g. send a CCIP message, observe it land): Pattern C (Tenderly VNets) handles cross-chain naturally because both chains live in the same project.
- **Pattern A** is for projects committed to anvil locally; doesn't add much over B in CI.

### Block pinning

Always pin the fork block in CI (`--fork-block-number` or `block_number:`). Without pinning, every run hits a different head block and intermittent state changes cause flaky tests.

### Matrix testing

```yaml
strategy:
  matrix:
    chain: [ethereum, arbitrum]
    include:
      - chain: ethereum
        rpc: ${{ secrets.ETH_RPC_URL }}
        block: 19500000
      - chain: arbitrum
        rpc: ${{ secrets.ARB_RPC_URL }}
        block: 200000000
```

---

## 6. JSONC parsing in Node

Three serious choices, picked by use case:

| Library | Comments preserved on stringify? | Best for | Notes |
|---|---|---|---|
| `strip-json-comments` | no | Strip comments then use native `JSON.parse` | Fastest. ~30 lines of regex. Doesn't handle trailing commas. |
| `jsonc-parser` | no | Read JSONC config files | Microsoft's; ships with VS Code. Handles trailing commas, single-line + multi-line comments. Returns AST + errors with positions. Best for fault-tolerant parsing of human-edited configs. |
| `comment-json` | yes | Round-trip JSONC | Preserves comments through parse -> mutate -> stringify. Use when you write JSONC back to disk. |

### Recommendation for catalogue config

If the catalogue is read-only at runtime: **`jsonc-parser`**. Reasons:
1. Tolerant parsing — returns errors as a list, doesn't throw on first issue, so you can show all problems in one report.
2. Position-aware errors — line/column for every error, which translates into useful "your config at line 47 col 12" output in the CLI.
3. Maintained by Microsoft alongside VS Code's JSONC support, so it tracks the JSONC spec.

If you also write the catalogue back (e.g. updating addresses after deploy): **`comment-json`**.

Avoid: `JSON5` for config files unless you specifically want the JS-flavoured extensions (identifier keys, single quotes). It's a strictly larger spec than JSONC and most editors handle JSONC better.

Sources:
- https://github.com/microsoft/node-jsonc-parser
- https://github.com/sindresorhus/strip-json-comments
- https://github.com/kaelzhang/node-comment-json

---

## 7. Reporting + audit trail

### Schema choices

- **SARIF** (Static Analysis Results Interchange Format) — https://sarifweb.azurewebsites.net/. JSON-based, IETF-style. GitHub Code Scanning ingests it natively (https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning). Use it when findings should show up as PR annotations or as a security dashboard.
- **JUnit XML** — universally consumed by CI dashboards (GitHub Actions test reporters, GitLab, Jenkins, CircleCI). Each parity check becomes a `<testcase>`; failures become `<failure>`. Less expressive than SARIF but works everywhere with zero setup.
- **Custom JSON** — most protocols (Aave, Compound) just emit their own JSON and let downstream tools transform.

### Convention for deploy-time evidence

Look at how Aave does it (the only protocol with a published convention):
- `reports/<reportName>_before.json` and `reports/<reportName>_after.json` — `{ raw: <stateDiff>, logs: <logs> }`.
- A markdown diff committed alongside the deploy PR (generated via `aave-cli diff` or `aave-helpers-js diff-snapshots`).
- The PR description links to the snapshot JSONs and the markdown diff.
- Sources: https://github.com/bgd-labs/aave-helpers/blob/main/src/ProtocolV3TestBase.sol, https://github.com/bgd-labs/aave-cli

Optimism convention (https://github.com/ethereum-optimism/superchain-ops):
- `VALIDATION.md` per task with expected domain hash + message hash + state changes.
- `README.md` per task explaining intent.
- Tenderly simulation link committed in the PR.

### Recommended approach for this project

Tiered output:
1. **Console** (cli-table3 + picocolors): human-readable parity matrix.
2. **JSON evidence** (`evidence/<chain>-<block>-<timestamp>.json`): structured findings, one entry per check. Custom schema is fine — model after Aave's `{ raw, logs }`.
3. **JUnit XML** (optional, behind `--junit-out` flag): for the CI dashboard. Library: `junit-report-builder` (https://www.npmjs.com/package/junit-report-builder) or hand-roll (XML is trivial).
4. **SARIF** (optional, only if PR-annotation surface is wanted): library `node-sarif-builder`.

The console + JSON evidence path covers 95% of needs. SARIF + JUnit are escape hatches for CI integration.

### Convention worth adopting

Commit a `VALIDATION.md` (steal from Optimism) alongside each deployment PR that captures:
- Expected on-chain addresses
- Expected role holders
- Expected proxy implementations
- Expected version strings
- Block at which the smoke test was run

This becomes the diff target for the next deploy. Reviewers approve VALIDATION.md; the CLI checks against it.

---

## 8. Pitfalls — reading on-chain state for parity

### viem decoder gotchas

**Named returns vs unnamed tuples.** viem only maps struct-typed returns to objects; unnamed multi-returns become arrays:

```solidity
// returns array [bigint, bigint, bigint, bigint, bigint]
function latestRoundData() returns (uint80, int256, uint256, uint256, uint80);

// returns object { roundId, answer, startedAt, updatedAt, answeredInRound }
function latestRoundData() returns (Data data); // where Data is a struct
```

If a getter returns multiple values without names, you'll get a TypeScript array. Hand-write a wrapper or fix the ABI to use a struct. https://viem.sh/docs/faq

**Tuples in `decodeAbiParameters`.** Use `parseAbiParameters` with parenthesised syntax for nested tuples:
```ts
parseAbiParameters('(uint256,address)[],bytes32')
```
Discussion: https://github.com/wevm/viem/discussions/1801

**Bigint everywhere.** viem returns `bigint` for `uint256`. Comparing to a JS number from a JSON config silently fails. Normalise both sides to `bigint` (or hex strings) before equality.

**`allowFailure: true` is the default for multicall.** A single reverting view function returns `{ status: 'reverted', error }` rather than throwing. If you treat results as always `data`-shaped, your TypeScript narrowing will mislead you. Always check `status` first.

### ERC-1967 slot reads

The implementation slot is `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` (`keccak256("eip1967.proxy.implementation") - 1`). Admin slot: `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`. Beacon slot: `0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50`.

```ts
const raw = await publicClient.getStorageAt({
  address: proxy,
  slot: '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',
});
// raw is a left-padded 32-byte hex; the implementation address is the last 20 bytes
const impl = `0x${raw!.slice(26)}` as `0x${string}`;
```

Pitfalls:
- `getStorageAt` is not batchable via Multicall3 (it's `eth_getStorageAt`, not `eth_call`). Use `Promise.all` with a concurrency limiter (e.g. `p-limit`).
- Pin to a `blockNumber` so the implementation read matches whatever you're reading from the proxy at the same block.
- Some custom proxies (e.g. transparent proxy with non-standard slot, beacon proxy, ERC-1822 / UUPS with overridden slot) won't be at the standard slot. Detect the pattern first or read multiple slots and assert exactly one is populated.
- Reference: https://eips.ethereum.org/EIPS/eip-1967

### Struct-returning getters

Solidity auto-generated getters for `mapping(uint => SomeStruct)` return the struct fields as a tuple, not a struct. If consumers rely on the named-field shape, they need an explicit `function getX(uint) external view returns (SomeStruct)`. Otherwise viem will decode to an array (see "Named returns vs unnamed tuples" above).

### Multicall caveats

- Multicall3 deployment address is `0xcA11bde05977b3631167028862bE2a173976CA11` on most chains. Verify via https://github.com/mds1/multicall before assuming.
- Each multicall is a single `eth_call`. A 500-call multicall with heavy view functions can exceed RPC gas limits (50M-ish on most providers). Split into chunks.
- `allowFailure: false` throws on the first revert across the whole batch — you lose visibility into which call failed unless you also do per-call introspection.

### Cross-chain parity (CCIP / a.DI specific)

- Reading state from two chains at the same wall-clock instant is meaningless; chains move at different rates. Either pin both to specific blocks (snapshot mode) or accept eventual consistency and check invariants that should hold regardless of timing.
- CCIP best-practices specifically: validate `msg.sender == router` on the receiver, verify the source chain selector, verify the source sender, implement replay protection. https://docs.chain.link/ccip/concepts/best-practices/evm
- a.DI bridge adapters need parity checks for: confirmations per chain, trusted senders set, bridge gas limits, validity envelope. Reference: https://github.com/aave-dao/aave-delivery-infrastructure

### General gotchas

- **Block reorgs during the read window.** If your script reads 500 values one by one over 30 seconds, blocks 1-50 can be reorged while you're reading 51-500. Always pin `blockNumber` or use multicall to atomise.
- **Proxy admin vs implementation reads.** Calling an admin-only view function from a non-admin EOA via `eth_call` succeeds (no msg.sender restriction on view), but a function that branches on `msg.sender` returns the EOA branch. Use `stateOverride` or impersonate when this matters.
- **RPC quirks.** Alchemy/Infura/QuickNode each have subtle differences in `debug_traceCall` and large batch behaviour. Standardise on multicall-based reads to stay portable.
- **ABI drift between deploy and check.** If the CLI reads from a static ABI bundled at build time but the deploy uses a different version, you get silent decoding mismatches. Either fetch ABI from Etherscan at run-time (via `eth-sdk`) or check the on-chain bytecode hash against an expected hash.

---

## Sources

### Aave
- https://github.com/bgd-labs/aave-helpers
- https://github.com/bgd-labs/aave-helpers/blob/main/src/ProtocolV3TestBase.sol
- https://github.com/bgd-labs/aave-cli
- https://github.com/aave-dao/aave-proposals-v3
- https://github.com/aave-dao/aave-delivery-infrastructure
- https://github.com/aave/aave-v3-deploy

### Optimism
- https://docs.optimism.io/operators/chain-operators/tools/op-validator
- https://github.com/ethereum-optimism/superchain-ops
- https://github.com/ethereum-optimism/optimism/blob/develop/op-chain-ops/README.md

### Compound, Safe, Maker, Morpho, Lido
- https://github.com/compound-finance/comet/blob/main/SCENARIO.md
- https://github.com/safe-global/safe-smart-account
- https://github.com/safe-global/safe-deployments
- https://docs.safe.global/core-api/safe-contracts-deployment
- https://community-development.makerdao.com/governance/executive-audit
- https://github.com/morpho-org/morpho-blue-deployment
- https://github.com/lidofinance/lido-l2
- https://docs.lido.fi/guides/multisig-deployment/

### Tooling
- https://github.com/Rubilmax/foundry-storage-check
- https://github.com/dethcrypto/eth-sdk
- https://github.com/wighawag/hardhat-deploy
- https://github.com/wighawag/forge-deploy
- https://getfoundry.sh/forge/reference/inspect/

### viem
- https://viem.sh/docs/contract/multicall
- https://viem.sh/docs/clients/public
- https://viem.sh/docs/contract/getStorageAt.html
- https://viem.sh/docs/faq
- https://github.com/wevm/viem/discussions/1801
- https://github.com/alessandroaw/viem-multicall-group
- https://github.com/mds1/multicall

### CLI libraries
- https://github.com/alexeyraspopov/picocolors
- https://nodejs.org/en/blog/migrations/chalk-to-styletext
- https://github.com/cli-table/cli-table3
- https://github.com/ayonious/console-table-printer
- https://github.com/sindresorhus/ora
- https://github.com/sindresorhus/boxen
- https://npmtrends.com/chalk-vs-picocolors

### JSONC
- https://github.com/microsoft/node-jsonc-parser
- https://github.com/sindresorhus/strip-json-comments
- https://github.com/kaelzhang/node-comment-json
- https://jsonc.org/

### CI and forking
- https://github.com/Tenderly/vnet-github-action
- https://docs.tenderly.co/virtual-testnets
- https://getfoundry.sh/anvil/reference/
- https://github.com/foundry-rs/foundry/issues/7631

### Reporting formats
- https://sarifweb.azurewebsites.net/
- https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning
- https://www.npmjs.com/package/junit-report-builder

### Cross-chain
- https://docs.chain.link/ccip/concepts/best-practices/evm
- https://eips.ethereum.org/EIPS/eip-1967

### RPC
- https://www.alchemy.com/docs/reference/batch-requests
- https://www.alchemy.com/docs/best-practices-when-using-alchemy
