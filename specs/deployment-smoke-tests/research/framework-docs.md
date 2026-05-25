# Framework documentation for the deployment smoke-test harness

Research compiled 2026-05-25. All version pins reflect the latest stable on npm / GitHub at that date.

---

## 1. viem

**Pinned version:** `viem@^2.51.0` (latest stable; 2.x line has been stable since 2024 and is the version Wagmi 2.x targets).

**Canonical docs:** https://viem.sh/docs

Installation:
```
npm i viem@^2.51.0
```

### 1.1 `createPublicClient` with custom RPC

```ts
import { createPublicClient, http } from 'viem';
import { arbitrum } from 'viem/chains';

const client = createPublicClient({
  chain: arbitrum,
  transport: http(process.env.ARB_RPC_URL, {
    batch: true,          // batches eth_call into one request
    retryCount: 3,
    retryDelay: 150,
    timeout: 30_000,
  }),
});
```

- Docs: https://viem.sh/docs/clients/public
- `http(url, opts)` accepts `batch`, `retryCount`, `retryDelay`, `timeout`, `fetchOptions`.
- If `url` is omitted, viem falls back to `chain.rpcUrls.default.http[0]` — for parity checks, always pass an explicit URL so the test pins the RPC.

### 1.2 `multicall` with `allowFailure: true`

```ts
const results = await client.multicall({
  contracts: [
    { address: vault,  abi: vaultAbi,  functionName: 'totalAssets' },
    { address: oracle, abi: oracleAbi, functionName: 'latestAnswer' },
  ],
  allowFailure: true,        // default; keep explicit for clarity
  batchSize: 2048,           // bytes of calldata per JSON-RPC request
});

for (const r of results) {
  if (r.status === 'success') { /* r.result is typed from ABI */ }
  else                        { /* r.error is a ContractFunctionExecutionError */ }
}
```

- Docs: https://viem.sh/docs/contract/multicall
- Return shape per call: `{ status: 'success', result: T } | { status: 'failure', error: Error }`.
- `batchSize: 0` disables splitting (single JSON-RPC). Default `1024` may be small for ~20 reads; bump to `2048`–`4096` on Arbitrum which tolerates large calldata.
- Requires `Multicall3` deployed on the chain — viem auto-resolves the address from `chain.contracts.multicall3.address`. All four chains we target ship with it.

### 1.3 `readContract` with typed ABIs

```ts
const abi = [{
  type: 'function', name: 'balanceOf',
  stateMutability: 'view',
  inputs:  [{ name: 'owner', type: 'address' }],
  outputs: [{ name: '',      type: 'uint256' }],
}] as const;   // ← critical: `as const` is what enables full type inference

const bal = await client.readContract({
  address: token, abi, functionName: 'balanceOf', args: [holder],
});
// bal is inferred as bigint
```

- Docs: https://viem.sh/docs/contract/readContract
- Without `as const`, `args` and the return are widened to `unknown` / `readonly unknown[]`.
- For multi-call typing, the same `as const` rule applies to each entry's `abi`.

### 1.4 `getStorageAt` for ERC-1967 slots

```ts
import { getAddress, pad, slice } from 'viem';

// well-known ERC-1967 slots (bytes32(keccak256("eip1967.*") - 1))
const IMPL_SLOT  = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';
const BEACON_SLOT= '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50';

const raw = await client.getStorageAt({ address: proxy, slot: IMPL_SLOT });
//          ^ Hex | undefined  (undefined if address has no code)
const impl = raw ? getAddress(`0x${raw.slice(-40)}`) : null;
```

- Docs: https://viem.sh/docs/contract/getStorageAt (path is under `contract/`, not `actions/public/` — older blog posts link the wrong URL).
- The three slots above are the ERC-1967 constants; encode them as 0x-prefixed bytes32 hex strings.
- `getStorageAt` returns `Hex` (32 bytes) or `undefined`. Use `slice(-40)` plus `getAddress` for the checksummed address.

### 1.5 Address utilities

| Function | Purpose |
|---|---|
| `getAddress(addr)` | EIP-55 checksum; throws on invalid input |
| `isAddress(s)` | format validation (no checksum enforcement) |
| `isAddressEqual(a, b)` | case-insensitive equality |
| `pad(hex, { size: 32 })` | left-pad to bytes32 |
| `slice(hex, start, end?)` | byte-range slice |

Docs: https://viem.sh/docs/utilities/getAddress

### 1.6 Chain definitions

```ts
import { mainnet, sepolia, arbitrum, arbitrumSepolia } from 'viem/chains';
```

- Docs: https://viem.sh/docs/chains/introduction
- Chain IDs: `mainnet` = 1, `sepolia` = 11155111, `arbitrum` = 42161, `arbitrumSepolia` = 421614.
- Each ships a `contracts.multicall3` entry, so `client.multicall` works without extra config.
- Source list: https://github.com/wevm/viem/tree/main/src/chains/definitions

### 1.7 Version pinning recommendation

Pin to `^2.51.0`. Reasons:
- 2.x is the only line with stable type-level ABI inference.
- 2.51 ships the multicall `batchSize` semantics this harness relies on.
- Avoid `latest` floating — viem ships breaking changes inside minor versions occasionally (most recently around `parseAbi` strictness).

---

## 2. tsx vs bun vs `node --experimental-strip-types`

**Pinned version:** `tsx@^4.22.3` (already on `tsx@^4.19.2` in repo; bump is safe — no breaking changes in 4.19→4.22).

**Canonical docs:** https://tsx.is and https://github.com/privatenumber/tsx

### Invocation

```bash
# one-off
npx tsx tools/smoke/run.ts

# watch
npx tsx watch tools/smoke/run.ts

# load env first
npx tsx --env-file=.env tools/smoke/run.ts
# (the repo already uses --env-file-if-exists for notion-sync.ts)
```

### What it is

tsx is a Node.js loader (`--loader` / `--import` hook) that uses esbuild to strip TypeScript syntax on the fly. It does no type-checking — that's tsc's job in CI.

### Performance (rough, from public benchmarks)

| Runtime | Cold start (hello world) | Realistic script |
|---|---|---|
| `bun run` | ~5 ms | ~18 ms |
| `node --strip-types file.ts` (Node 22+) | — | ~95 ms |
| `npx tsx file.ts` | ~18 ms | ~280 ms |
| `ts-node` | ~700 ms | several seconds |

For an RPC-bound smoke test the runtime startup is irrelevant — network calls dominate. tsx is the right choice for this repo.

### Source maps

- tsx generates inline source maps via esbuild. Stack traces point at the original `.ts` line.
- Known limitation: esbuild may rename variables in minified mode; tsx does not minify, so this is not an issue in normal use. See https://github.com/privatenumber/tsx/issues/98 for context.

### ESM / CJS interop — gotchas

- tsx reads `package.json#type` to decide whether each `.ts` file is ESM or CJS. The repo's `tools/roles/` does not set `type`, so files are CJS by default. Add `"type": "module"` to `tools/smoke/package.json` (or to a local `package.json` next to the smoke harness) to keep it ESM.
- Under NodeNext, imports require explicit `.js` extensions (`import './foo.js'`). tsx accepts both `./foo.js` and `./foo.ts`, but tsc in CI will reject extensionless imports.
- Importing a CJS package's named exports from an ESM file occasionally fails when the CJS package uses conditional exports — workaround is `import pkg from 'cjs-pkg'; const { x } = pkg;`. Tracked at https://github.com/privatenumber/tsx/issues/614.
- `__esModule` interop is applied to `.cjs` files by tsx but not by Node natively; if you import a `.cjs` you authored, prefer the default-export pattern. See https://github.com/privatenumber/tsx/issues/627.

### Why not bun for this harness

- Bun is faster but introduces a second runtime in CI and locally. The repo standardises on `tsx` already (`tools/roles/`). Mixing would create drift.
- Bun's TypeScript path resolution differs subtly (e.g. `tsconfig.paths`); switching mid-project usually surfaces small bugs.

### Why not `node --experimental-strip-types`

- Stable from Node 22.18 / 24.12; enabled by default on 23.6+. Removes the flag entirely in v26.
- Limitations: no enums, no namespaces with runtime code, no decorators, no parameter properties. Imports must include explicit extensions.
- For a tools/ harness with a couple of files, it works. But it ignores `tsconfig.json#paths` and produces no transpilation diagnostics. Stick with tsx.

Docs: https://nodejs.org/api/typescript.html

---

## 3. TypeScript 5.x strict tsconfig for a `tools/`-style folder

**Pinned version:** `typescript@^5.7.3` (matches what `package.json` already has).

**Canonical docs:** https://www.typescriptlang.org/tsconfig

### Recommended `tools/smoke/tsconfig.json`

```jsonc
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022"],

    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitOverride": true,
    "noFallthroughCasesInSwitch": true,

    "verbatimModuleSyntax": true,
    "isolatedModules": true,        // matches what esbuild/tsx assume
    "esModuleInterop": true,
    "resolveJsonModule": true,
    "allowImportingTsExtensions": false,

    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "noEmit": true,                 // tsc is type-check only; tsx runs the code

    "types": ["node"]
  },
  "include": ["**/*.ts"]
}
```

### Why these flags, specifically

- `module: NodeNext` over `Bundler` — `Bundler` skips Node's resolution rules (no required extensions, no `package.json#exports` enforcement). For a script the runtime is Node; matching its rules in tsc catches `import` mistakes before runtime.
- `verbatimModuleSyntax: true` forces `import type` / `export type` to be written explicitly. Removes the dual-mode ambiguity that tsx's esbuild step is bad at guessing.
- `isolatedModules: true` is mandatory under any single-file transpiler (esbuild, swc). It rejects cross-file type-erasure patterns that those tools can't see.
- `noUncheckedIndexedAccess: true` — already on in the roles tsconfig; very valuable for parity scripts that index into arrays from JSONC.
- `exactOptionalPropertyTypes: true` — strict; pairs well with discriminated unions in result types.

### CI type-check

```bash
npx tsc -p tools/smoke/tsconfig.json --noEmit
```

`--noEmit` is redundant given the file's `noEmit: true`, but harmless and explicit.

### Note on the existing `tools/roles/tsconfig.json`

That one uses `module: ES2022` + `moduleResolution: Bundler`. It works because the scripts are simple and tsx doesn't enforce extensions. For the smoke harness, prefer NodeNext — it produces more accurate diagnostics for the imports we'll write against viem and `node:*` builtins.

---

## 4. JSONC parsing for source-position errors

**Recommendation:** `jsonc-parser@^3.3.1` (already a dep in `package.json`). It's the only one of the three that gives you full line/column information after parsing.

### Comparison

| Library | Comments? | Preserves comments on stringify? | Line/column? | Size |
|---|---|---|---|---|
| `jsonc-parser` (Microsoft, ships in VS Code) | yes | no | **yes — full offset / line / column via `visit`, `parseTree`, `getLocation`** | tiny |
| `comment-json` | yes | yes | partial — comment positions only, not full path locations | medium |
| `strip-json-comments` | yes (strips them) | no | no — just text in/out | tiny |

### `jsonc-parser` API for source positions

```ts
import { parse, parseTree, findNodeAtLocation, getNodePath, type Node } from 'jsonc-parser';

const text = await readFile('parity.jsonc', 'utf8');
const root = parseTree(text)!;            // Node with .offset, .length, .children, .type
const node = findNodeAtLocation(root, ['assets', 0, 'address']);
// node!.offset is the byte offset of the value in the source

// to get line/column from an offset:
function lineCol(src: string, off: number) {
  let line = 1, col = 1;
  for (let i = 0; i < off; i++) {
    if (src.charCodeAt(i) === 10) { line++; col = 1; } else { col++; }
  }
  return { line, col };
}
```

Alternative: the `visit` SAX-style API delivers `line` and `column` directly to each callback, no manual counting needed.

Docs: https://github.com/microsoft/node-jsonc-parser (README has the full visitor signature).

### Why not `comment-json`

If you need to round-trip JSONC (parse → edit → write with comments preserved), `comment-json@^5.0.0` is the right tool. For *reporting* errors with a line number, it's heavier and less ergonomic — `jsonc-parser` is purpose-built.

### Why not `strip-json-comments`

It throws away the only thing you need (positions). Skip it.

---

## 5. Output libraries

### 5.1 `picocolors` — `^1.1.1`

```ts
import pc from 'picocolors';
console.log(pc.green('OK'), pc.dim('· checked 12 reads'));
console.log(pc.red(pc.bold('FAIL')));
```

- Docs: https://github.com/alexeyraspopov/picocolors
- API: `black red green yellow blue magenta cyan white gray` + `bright` variants, `bg*` variants, `bold dim italic underline strikethrough inverse hidden reset`.
- No method chaining — nest calls: `pc.red(pc.bold(x))`.
- Respects `NO_COLOR` and `FORCE_COLOR`. Ships CJS+ESM, zero deps.
- Last published 2024 but stable and feature-complete; no maintenance gap concern.

### 5.2 `cli-table3` — `^0.6.5`

```ts
import Table from 'cli-table3';

const t = new Table({
  head: ['key', 'expected', 'actual', 'status'],
  colWidths: [28, 24, 24, 10],
  wordWrap: true,
  style: { head: ['cyan'], border: ['gray'] },
});

t.push(
  ['vault.totalAssets()', '12345e18', '12345e18', pc.green('OK')],
  ['oracle.latestAnswer()', '—',      'reverted', pc.red('FAIL')],
);
console.log(t.toString());
```

- Docs: https://github.com/cli-table/cli-table3
- ANSI-aware: cell widths and alignment ignore color escape codes when measuring length. Safe to colour cells with picocolors.
- Per-cell alignment: `{ content: '…', hAlign: 'right', vAlign: 'center' }`.
- `wordWrap: true` wraps on word boundaries inside `colWidths`.
- Custom borders via `chars: { ... }` (full Unicode set); set every entry to `''` for a borderless table.

### 5.3 `ora` — `^9.4.0`

```ts
import ora from 'ora';

const spinner = ora('Fetching impl slot…').start();
try {
  const impl = await client.getStorageAt({ address, slot: IMPL_SLOT });
  spinner.succeed(`impl = ${impl}`);
} catch (e) {
  spinner.fail(`getStorageAt failed: ${(e as Error).message}`);
}
```

- Docs: https://github.com/sindresorhus/ora
- `.succeed() .fail() .warn() .info() .stop() .clear()` stop the spinner and print a symbol.
- Mutate `.text` mid-spin; `.color` accepts standard chalk-style names.
- **Pure ESM since v6.** This means a `tools/smoke/package.json` with `"type": "module"` is non-optional.
- If you ever need CJS, fall back to `ora-classic@^5.4.1`.
- `oraPromise(promise, text)` is the convenience wrapper for one-shot async calls.

---

## 6. Foundry CLI invocation from TypeScript

**Pinned via toolchain action:** `foundry-rs/foundry-toolchain@v1` (latest is v1.8.0, April 2026). Locally the harness should assume the dev has `cast`/`forge`/`anvil` on PATH; the GHA step installs them.

**Canonical docs:** https://getfoundry.sh (note: `book.getfoundry.sh` 301-redirects to `getfoundry.sh` as of early 2026).

### 6.1 `cast call` — view function over RPC

```bash
cast call <ADDRESS> "balanceOf(address)(uint256)" <HOLDER> --rpc-url $RPC
```

- Function selector is the signature with input types and (optionally) output types. Output types make `cast` decode for you.
- `--block <N>` to pin a block.
- Reference: https://getfoundry.sh/cast/reference/

### 6.2 `cast code` — deployed bytecode

```bash
cast code <ADDRESS> --rpc-url $RPC                       # returns 0x… runtime bytecode
cast code <ADDRESS> --rpc-url $RPC | wc -c               # length check (counts hex chars)
```

Use this to confirm a proxy actually has code at the expected address, and to compare runtime bytecode against `forge inspect <C> deployedBytecode` for an exact match cross-check.

### 6.3 `forge inspect` — local artifact fields

```bash
forge inspect MyVault abi              --json
forge inspect MyVault bytecode         # creation bytecode
forge inspect MyVault deployedBytecode # runtime bytecode — compare to cast code
forge inspect MyVault storageLayout    --json
forge inspect MyVault methodIdentifiers --json
```

- Reference: https://getfoundry.sh/forge/reference/inspect/
- Aliases: `b` / `bytes` / `bytecode`; `storage` / `storage-layout`.
- `--json` is essential when piping into TS — the default human format is hard to parse.

### 6.4 Invoking from TS

```ts
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);

const { stdout } = await run('forge', ['inspect', 'MyVault', 'deployedBytecode']);
const expected = stdout.trim();

const { stdout: actual } = await run('cast', ['code', address, '--rpc-url', rpc]);
assert(expected === actual.trim(), 'runtime bytecode mismatch');
```

Prefer `execFile` over `exec` — it avoids shell injection on user-controlled addresses/URLs.

---

## 7. GitHub Actions: forked anvil + tsx harness

**Pinned action:** `foundry-rs/foundry-toolchain@v1` (latest stable 1.8.0).

**Canonical docs:** https://github.com/foundry-rs/foundry-toolchain · https://getfoundry.sh/anvil/

### Anvil flags

```bash
anvil \
  --fork-url $RPC_URL \
  --fork-block-number 19000000 \
  --port 8545 --host 127.0.0.1 \
  --dump-state ./anvil-state.json \   # write state on exit
  --load-state ./anvil-state.json     # or use --state for both
```

- `--state <path>` is the shorthand for `--load-state` + `--dump-state` on the same file.
- `--fork-url` accepts multiple endpoints (comma- or space-separated) for load balancing.
- Default port 8545; default host 127.0.0.1.

### Workflow shape

```yaml
name: smoke-tests

on:
  pull_request:
  workflow_dispatch:

jobs:
  smoke:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    env:
      ARB_FORK_BLOCK: '250000000'

    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - uses: foundry-rs/foundry-toolchain@v1
        with:
          version: stable          # or pin: v1.5.0

      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'yarn'            # or 'npm'

      - run: yarn install --frozen-lockfile

      # cache the RPC fork data Foundry keeps in ~/.foundry/cache/rpc
      - uses: actions/cache@v4
        with:
          path: ~/.foundry/cache/rpc
          key: foundry-rpc-arb-${{ env.ARB_FORK_BLOCK }}
          restore-keys: foundry-rpc-arb-

      - name: Start anvil (background)
        run: |
          anvil \
            --fork-url "${{ secrets.ARB_RPC_URL }}" \
            --fork-block-number "$ARB_FORK_BLOCK" \
            --port 8545 \
            --silent &
          echo $! > anvil.pid
          # wait for RPC to come up
          npx --yes wait-on tcp:127.0.0.1:8545

      - name: Smoke harness
        env:
          RPC_URL: http://127.0.0.1:8545
        run: yarn tsx tools/smoke/run.ts

      - name: Stop anvil
        if: always()
        run: kill $(cat anvil.pid) || true
```

### Key points

- The toolchain action's built-in cache covers `~/.foundry/cache/rpc` automatically when used together with `forge test`. For a standalone `anvil` invocation, add an explicit `actions/cache` step keyed on the fork block — second runs at the same block hit the cache and skip RPC fetches.
- Pin the fork block. Without it, every run hits a different head block and cache hits never occur.
- The official action also exposes `cache: false` and `cache-key` / `cache-restore-keys` if you need finer control. See https://github.com/foundry-rs/foundry-toolchain/blob/master/action.yml.
- `actions/cache` retains entries for 7 days of inactivity, capped at 10 GB per repo — fine for a fork cache (~tens of MB).
- Persisting state *across* runs (so the harness can re-use mutated state) is doable with `anvil --state ./state.json` + `actions/upload-artifact` or `actions/cache`, but for smoke tests it's usually preferable to start fresh from the fork each run for determinism.

### `anvil` state persistence — caveats

- `--dump-state` writes on graceful shutdown (SIGINT). `kill -9` skips the dump.
- The cache at `~/.foundry/cache/rpc/<chain>/<block>` is per-block-per-chain. If the harness needs multiple chains in one job, cache the whole `rpc/` directory.
- Known issue: anvil dirties the fork cache with locally written state when both forking and writing — track https://github.com/foundry-rs/foundry/issues/1531.

---

## Quick version-pin reference

```jsonc
// package.json (devDependencies)
{
  "viem":         "^2.51.0",
  "tsx":          "^4.22.3",
  "typescript":   "^5.7.3",
  "jsonc-parser": "^3.3.1",
  "picocolors":   "^1.1.1",
  "cli-table3":   "^0.6.5",
  "ora":          "^9.4.0",
  "@types/node":  "^22.10.5"
}
```

GitHub Action pin: `foundry-rs/foundry-toolchain@v1` (resolves to 1.8.0+).

---

## Reference index

- viem docs: https://viem.sh/docs
- viem multicall: https://viem.sh/docs/contract/multicall
- viem readContract: https://viem.sh/docs/contract/readContract
- viem getStorageAt: https://viem.sh/docs/contract/getStorageAt
- viem chains source: https://github.com/wevm/viem/tree/main/src/chains/definitions
- tsx: https://tsx.is · https://github.com/privatenumber/tsx
- Node native TS: https://nodejs.org/api/typescript.html
- TypeScript tsconfig: https://www.typescriptlang.org/tsconfig
- jsonc-parser: https://github.com/microsoft/node-jsonc-parser
- picocolors: https://github.com/alexeyraspopov/picocolors
- cli-table3: https://github.com/cli-table/cli-table3
- ora: https://github.com/sindresorhus/ora
- Foundry: https://getfoundry.sh
- forge inspect: https://getfoundry.sh/forge/reference/inspect/
- anvil: https://getfoundry.sh/anvil/
- foundry-toolchain action: https://github.com/foundry-rs/foundry-toolchain
- ERC-1967 spec: https://eips.ethereum.org/EIPS/eip-1967
