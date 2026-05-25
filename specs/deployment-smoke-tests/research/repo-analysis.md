# Repository Research — stable-vault smoke-test harness context

> Branch: `enh/scripts` (PR 309 tip). Findings extracted by the repo-research-analyst agent.

## Tech & infrastructure

- **Languages:** Solidity 0.8.28 (some interfaces pinned to ^0.8.22) + TypeScript 5.7.3 for tooling.
- **TS runtime:** `tsx ^4.19.2`. No bun, no node24. CI uses `node-version: 22`.
- **Module system:** ESM. `tools/roles/tsconfig.json:2-13` sets `"module": "ES2022"`, `"moduleResolution": "Bundler"`, `"strict": true`, `"noUncheckedIndexedAccess": true`, `"esModuleInterop": true`, `"resolveJsonModule": true`. All relative imports use `.js` suffix even from `.ts` sources.
- **JS deps** (`package.json:2-15`): `@notionhq/client ^4.0.2`, `@types/node ^22.10.5`, `jsonc-parser ^3.3.1`, `tsx`, `typescript`, `husky`. **No viem pinned anywhere** — adding it is a fresh decision.
- **Forge tooling:** foundry-stable in CI.
- **Deployment model:** multi-chain (AC + EC) via CREATE3 deterministic addresses, transparent proxies for upgradeables, CCIP + a.DI bridge adapters. Three envs: `staging | preprod | prod` (`tools/roles/lib/types.ts:1-3`).
- **Conventions:** strict, ESM, `.js` suffix on relative imports, no emojis. `forge fmt` enforced via `lint-staged` + CI. `forge build --deny notes` fails on `// note:` comments.

## Tools layout to mirror — `tools/roles/`

- `tools/roles/build-roles-json.ts` — pipeline driver. Reads `RolesConfig.sol` + three `AccessManager*Setup.sol` + `out/` Foundry artefacts + three `roles.dump.<env>.json`. Writes `script/output/roles.json`. Entrypoint hard-codes `REPO_ROOT = process.cwd()` (line 37) — must run from repo root.
- `tools/roles/validate-roles-json.ts` — invariant checker (selector/key/roleId uniqueness, delay tier ordering, profile-grant policy).
- `tools/roles/notion-sync.ts` — Notion upsert. Idempotent: human-edited columns (`Notes`, `What it controls`, `Risks`) survive. Orphans flipped to `Status=Removed`. `NOTION_DRY_RUN=1` for dry-run.
- `tools/roles/lib/types.ts` — `Env = "staging" | "preprod" | "prod"` (line 1). `ENVS` is the iteration source.
- `tools/roles/lib/parameters-spec.ts` — **the catalogue you'll mirror.**
- `tools/roles/lib/parameters.ts` — expands `ParameterSpec[]` against the three JSONC configs. `loadDeploymentConfigs(repoRoot)` (lines 33-53) is the JSONC loader entry point; `getByPath` (lines 235-244) is the leaf accessor.
- `tools/roles/lib/parse-solidity.ts` — regex parser for `RolesConfig.sol` natspec. Not directly needed for smoke.
- `tools/roles/lib/load-signatures.ts` — Foundry artefact reader. Walks `out/<file>.sol/<Contract>.json`, reads `methodIdentifiers`, falls back to `forge inspect <contract> methodIdentifiers --json` via `execFileSync`. **Reusable for getter selector lookup.**

### Shape of `parameters-spec.ts`

```ts
export interface ParameterSpec {
  key: string;
  contract: string;
  category: "Yield economics" | "Withdrawal fees + signers" | ...;
  chainContext: ChainContext;            // "AC" | "EC" | "AC+EC" | ""
  setterKeys: string[];                  // role keys; empty for immutables
  unit: string;
  onChainLimits: string;
  value: ValueSpec;
}

export type ValueSpec =
  | { type: "scalar"; path: string; format: ValueFormat }
  | { type: "perAsset"; pathTemplate: string; assets: AssetKey[]; format: ValueFormat };
```

`ValueFormat` (lines 29-39): `raw | bps | seconds | ray | rayPerSec | assetWei | assetWeiPerSec | bool | address | uint`. The humanise functions in `parameters.ts:110-228` already implement formatting algorithms for each — **smoke output reuses these verbatim.**

`AssetKey`: `"gho" | "usdc" | "usdt"`. `PARAMETER_SPECS` is an array of 49 entries grouped into 11 categories.

**Extension path for smoke:** add a `getter` field next to `setterKeys` (or build a sibling `GETTER_SPECS` keyed by the same `key`).

## Deployment artefact schema

`script/base/BaseChainDeployment.sol:256-272` writes entries via `vm.writeJson(jsonObject, deploymentOutputPath, ".<name>")`. Each entry:

```json
"<Name>": { "address": "0x…", "saltSeed": "<seed-string-or-empty>" }
```

`aTokenVaults` is a JSON array under `.aTokenVaults` with per-entry `{address, assetSymbol}`.

Real shape (`deployments/preprod/v1/accounting.json`):

```json
{
  "TransferHelper": { "address": "0x1cc0…dab", "saltSeed": "aave.stable-vault.TransferHelper" },
  "AccessManager":  { "address": "0xe468…8c6", "saltSeed": "aave.stable-vault.AccessManager" },
  "AssetRegistry::Implementation": { "address": "0x4fb3…2bb", "saltSeed": "" },
  "AssetRegistry":  { "address": "0x1ac7…25c", "saltSeed": "aave.stable-vault.AssetRegistry" },
  "aTokenVaults": [
    { "address": "0x2FDE6…1Df50", "assetSymbol": "GHO" },
    ...
  ]
}
```

Implementation entries use `::Implementation` suffix with empty `saltSeed` (regular `CREATE`'d). Both CREATE3 proxies and CREATE'd impls share this single file.

EC variant (`deployments/preprod/v1/earning.json`) has `EarningChainGateway`, `EarningChainStateProvider`, `ChainlinkPriceOracleAdapter::*` (no L2 suffix). No `ChainBalanceOracle` and no `FundsHandler`.

## CREATE3 algorithm to port to viem

`script/libraries/Create3AddressLib.sol:8-66` against createx factory `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`. Two-stage salt:

1. `salt = keccak256(seed) & DEPLOYER_ZEROING_MASK & CROSS_CHAIN_PROTECTION_MASK | (deployer << 96)`
2. `keccak256(deployer ++ salt)`, then standard CREATE address.

Salt seeds enumerated at `script/base/Create3AddressBook.sol:12-41`:

- `"aave.stable-vault.StableVault"`, `"…TransferHelper"`, `"…WithdrawalExecutionPolicy"`, `"…FundsHandler"`, `"…Allocator"`, `"…Gateway"`, `"…AccessManager"`, `"…AssetRegistry"`, `"…IouTokenManager"`, `"…IouToken"`, `"…SlippageCoverageVault"`, `"…Swapper"`, `"…CcipAdapter"`, `"…AdiAdapter"`, `"…PriceOracle"`, `"…ChainBalanceOracle"`, `"…EarningChainStateProvider"`, `"…PolicyRegistry"`, `"…DepositPolicy"`, `"…FundsBridgingPolicy"`, plus per-asset/per-chain prefixed seeds for ATokenVault, ChainlinkPriceOracleAdapter, etc.

## JSONC config shape (preprod top-level)

Top-level keys: `deployer`, `lowDelay`, `mediumDelay`, `highDelay`, `criticalDelay`, `maxStrategiesPerAsset`, `chainlinkPriceOracleHeartbeat`, `chainlinkChainBalanceOracleHeartbeat`, `priceOracleMinValidPriceRay`, `iouTokenName`, `iouTokenSymbol`.

Maps: `profiles.{mainAdmin,secondaryAdmin,rebalancerMulticallOwner,disablerMulticallOwner,withdrawalPolicyManager,aTokenVaultRewardClaimer,stableVaultManager,coverageGuardian,funder}`.

Policies (scalars + per-asset): `withdrawalExecutionPolicy.{defaultFeeBps,signer}`; `slippageCoverageVault.{maxSlippageBps,overrideMaxSlippageBps,initialOverrideMode,perAssetCaps.<asset>.{pullCapPerTx,windowCap,windowSeconds}}`.

Chain blocks: `earningChain.*` + `accountingChain.*` each carry `chainId, ccipSelector, assets.<asset>, chainlinkFeeds.<feed>, ccipRouterAddress, adi.{crossChainController,registerOnGateway}, fundsBridgingPolicy.perAssetLimits.<asset>.{capacity,refillRate}, withdrawalExecutionPolicy.{redemptionLimit.{capacityRay,refillRateRay},minRedemptionCapacityRay,minRedemptionRefillRateRay}, deploymentOutputPath`.

AC-only: `defaultMaxPerSecondRate, defaultSubVaultPerSecondRate, defaultMaxActiveSubVaults, stableVaultName, stableVaultSymbol, useMockBundleFeed, useMockSequencerUptimeFeed, chainlinkBundleAggregatorProxy, sequencerUptimeFeed, depositPolicy.perAssetLimits.*`.

EC-only: `erc4626Strategies` (array of `{address, underlyingAddress, assetSymbol, strategySymbol}`), `minBurnIouTokenGasLimit`.

**Number coercion gotcha:** most uint values are JSON strings (RAY values, ccipSelector, capacities). Some are JSON numbers (`defaultMaxActiveSubVaults`, `maxStrategiesPerAsset`, delay seconds, `windowSeconds`). The smoke comparator must coerce both sides to `bigint` before comparison. The Solidity side handles this via `_configUint`'s fallback from `vm.parseJsonUint` to `vm.parseUint(vm.parseJsonString(…))` (`script/base/DeploymentConfig.sol:24-31`).

## Interfaces to call

| Surface | Where the getters live |
|---|---|
| `IStableVault` | `src/interfaces/IStableVault.sol:185-267`: `getDefaultSubVault()`, `getMaxValidPerSecondRate()`, `getTreasury()`, `getSubVaultRateById()`, `getSubVaultIdByRate()`, `getActiveSubVaults()`, `getUserSubVault()`, `getGlobalOriginalDepositAmount()`, `getClaimableSurplusInterest()`, `getSubVaultConversionRate()`. |
| `IAssetRegistry` | Interface (`src/interfaces/IAssetRegistry.sol:104-150`): `isAssetRegistered`, `isAssetTrusted`, `isDepositToAllocatorAllowed`, `isSwapInputAllowed`, `isSwapOutputAllowed`, `isUserDepositAllowed`, `getTrustedAssets`. **Impl** (`src/periphery/AssetRegistry.sol:163-211`): `getRegisteredAssets`, `getAssetConfig(asset)`. |
| `IAllocator` | `src/interfaces/IAllocator.sol:216-269`: `getAssetBalance`, `getAssetBalanceInStrategy`, `getTrustedAssetBalances`, `getTrustedAssetBalance`, `getStrategiesForAsset`, `getWithdrawalQueue`, `getStrategyConfig`, `isStrategySupportedForAsset`, `isStrategySupported`, `isStrategyTrusted`. |
| `IWithdrawalExecutionPolicy` | Interface only has apply/preview. **Impl** (`src/policies/WithdrawalExecutionPolicy.sol:225-263`): `getAssetFeeConfig`, `getDefaultFeeBps`, `isSigner`, `wasNonceUsed`, `getRedemptionBucket`, `getMinRedemptionCapacity`, `getMinRedemptionRefillRate`. |
| `IDepositPolicy` | Interface only has apply/preview. **Impl** (`src/policies/DepositPolicy.sol:64`): `getDepositLimit(asset)`. |
| `IFundsBridgingPolicy` | Interface only has apply/preview. **Impl** (`src/policies/FundsBridgingPolicy.sol:106`): `getBridgingLimit(asset, destChainId, bridgeAdapter)`. |
| `ISlippageCoverageVault` | Interface has only `getEffectiveMaxSlippageBps`. **Impl** (`src/periphery/SlippageCoverageVault.sol:261-293`): `getBeneficiary`, `getOverrideMode`, `getPullCapPerTx`, `getWindow`, `getMaxSlippageBps`, `getOverrideMaxSlippageBps`, `getEffectiveMaxSlippageBps`. |
| `IPriceOracle` | `src/interfaces/IPriceOracle.sol:23-32`: `getPrice`, `getPrices`, `validatePrice`. **Impl** (`src/oracles/price/PriceOracle.sol:95`): `getOracleAdapterForAsset`. |
| `IChainBalanceOracle` | `src/interfaces/IChainBalanceOracle.sol:23-27`: `getChainBalance(chainId) → ChainBalance{balanceRay, lastUpdateTimestamp, sourceChainTimestamp, sourceChainBlockNumber, isStale}`. **Impl** (`src/oracles/balance/ChainBalanceOracle.sol:75`): `getChainBalanceOracleAdapter(chainId)`. |
| `IIouTokenManager` | `src/interfaces/IIouTokenManager.sol:75-84`: `getAsset`, `getLockedBalance`. |
| `IChainGateway` | `src/interfaces/IChainGateway.sol:131`: `getIouTokenManager`. **Impl** (`src/core/BaseChainGateway.sol:72-78`): `isBridgeAdapterSupported(asset, chainId, bridgeAdapter)`. AC variant: `getFundsHandler`. EC variant: `getAccountingChainId`, `getAggregatedBalance`. |
| `IBridgeAdapter` | `src/interfaces/IBridgeAdapter.sol:83-88`: `getGateway`, `getDataOnlyReceiveGasOverhead`. **Impl** (`src/bridging/BaseBridgeAdapter.sol:59`): `getDestinationChainAdapter(chainId)`. |
| `ICcipBridgeAdapter` | `src/interfaces/ICcipBridgeAdapter.sol:48-58`: `getRouter`, `getChainSelector`, `getChainId`. |
| `FundsHandler` | `src/core/accounting/FundsHandler.sol:115-120`: `getEarningChainIds`, `getAggregatedBalance`. |

### Cross-reference gap (important)

`StableVault.sol:115-127` declares the cross-reference immutables as `internal immutable`:

```solidity
address internal immutable ASSET_REGISTRY;
address internal immutable IOU_TOKEN_MANAGER;
uint256 internal immutable MAX_VALID_PER_SECOND_RATE;
address internal immutable FUNDS_HANDLER;
address internal immutable PRICE_ORACLE;
uint256 internal immutable MAX_ACTIVE_SUB_VAULTS;
address internal immutable POLICY_REGISTRY;
```

No public accessors. Allocator and FundsHandler likely have the same shape.

**Implication for v1:** rely on CREATE3 re-derivation + artefact match (both deployer and salt seeds are fixed), or propose adding public accessors as a sibling PR. Per the global CLAUDE.md "Minimal API surface on admin / emergency paths" rule, surface the decision before adding accessors.

## Existing tests

- `test/e2e/` — full-system simulation in-memory (not against a real deploy).
- `test/integration/<Policy>AccessManager.t.sol` — role-restriction tests per profile.
- `test/integration/adi/` — six AdiAdapter Pigeon fork tests.
- `test/script/libraries/JsoncSupport.t.sol` — JSONC parsing tests with fixtures under `test/resources/jsonc/`.
- `test/unit/script/` — `ATokenVaultCreate3ProxyDeployer.t.sol`, `DeploymentConfig.t.sol`.

**No existing post-deploy smoke against a live deployment.** Smoke harness is the first artefact of this kind.

## CI workflows that run on every PR

| File | Trigger | Purpose |
|---|---|---|
| `test.yml` | PR + master + manual | `lint` (forge fmt + check-error-selectors), `build` (`forge build --deny notes`), `sizes`, `test` (`forge test -vvv`), `gas-diff` |
| `roles-sync.yml` | PR + master + manual | Build + validate `roles.json`, fail on diff vs committed, sync to Notion on master push |
| `dependency-review.yml` | PR | `actions/dependency-review-action@v4` with fail-on `moderate` |
| `check-error-selectors.sh` | invoked by test.yml lint | Validates `@custom:selector` annotations |
| `gas-diff.sh` | invoked by test.yml gas-diff | Snapshot diff |
| `strip-jsonc.sh` | invoked by test.yml test + gas-diff | Pre-strips JSONC for Solidity (`JSONC_PRESTRIPPED=true`) |

The `test.yml` test/gas-diff jobs both pre-strip JSONC. If smoke is wired into CI, it uses `jsonc-parser` directly — no strip step needed.

## Makefile

`Makefile` has `build`, `test`, `coverage-unit`, `gas-report`, `clean`, `format`, `update`. **No deploy or smoke targets.** Adding `make smoke ENV=preprod CHAIN=accounting` is a clean extension.

## Yarn script pattern (from `tools/roles/`)

```json
"roles:dump":   "forge script ... && ... && ...",
"roles:build":  "tsx tools/roles/build-roles-json.ts",
"roles:validate": "tsx tools/roles/validate-roles-json.ts",
"roles:all": "yarn roles:dump && yarn roles:build && yarn roles:validate",
"roles:notion-sync": "tsx --env-file-if-exists=.env tools/roles/notion-sync.ts"
```

Pattern for smoke: `yarn smoke:run` (or `smoke:preprod` / `smoke:staging`) with `tsx tools/smoke/run.ts`.

## Output paths

- `script/output/roles.json` is **committed**; `script/output/roles.dump.*.json` is gitignored.
- `deployments/` is committed (produced by `forge script` deploy runs).
- `snapshots/` is gitignored.
- **`tools/smoke/output/`** per the interview decision — gitignored content with `.gitkeep` to preserve directory. Pattern: `<env>-<chain>-<ISO-timestamp>.json`.

## Specific paths most relevant to next steps

- `tools/roles/lib/parameters-spec.ts` — extend for getters
- `tools/roles/lib/parameters.ts` — reuse `loadDeploymentConfigs` + `getByPath`
- `tools/roles/lib/load-signatures.ts` — reuse for selector lookups
- `tools/roles/lib/types.ts` — `Env`, `ENVS`, value-format types to mirror
- `tools/roles/tsconfig.json` — copy as base for `tools/smoke/tsconfig.json`
- `script/base/BaseChainDeployment.sol:256-272` — artefact schema source-of-truth
- `script/base/Create3AddressBook.sol` — salt seed inventory
- `script/libraries/Create3AddressLib.sol` — CREATE3 algorithm to port to viem
- `deployments/preprod/v1/{accounting,earning}.json` — real artefacts
- `config/deployment-config.preprod.jsonc` — config schema reference
- `.github/workflows/roles-sync.yml` — CI workflow template
