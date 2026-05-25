// GETTER_SPECS: one entry per JSONC config leaf that becomes on-chain state.
// Pairs each leaf with the contract + getter that reads it back.
//
// v1 covers DepositPolicy, FundsBridgingPolicy, SlippageCoverageVault as proof
// of pattern. Remaining groups (StableVault, AccessManager profile assignments,
// AssetRegistry per-asset flags, Allocator strategies, Oracles, Bridges,
// WithdrawalExecutionPolicy) are stubbed with `// TODO(VA-229)` markers — same
// pattern, more entries. The parity engine doesn't care which groups are
// populated; adding a new entry here is the only change needed to cover a new
// parameter end-to-end.

import { type Abi, type Address, getAddress } from "viem";

import type { DeploymentArtefact } from "../types.js";
import { tryEntry } from "../artefact.js";
import { DEPOSIT_POLICY_ABI, FUNDS_BRIDGING_POLICY_ABI, SLIPPAGE_COVERAGE_VAULT_ABI } from "./abis.js";
import type { GetterSpec } from "../parity.js";

type ChainConfig = Record<string, unknown>;

export interface BuildArgs {
  config: Record<string, unknown>;
  artefact: DeploymentArtefact;
  chain: "accounting" | "earning";
}

const ASSETS = ["gho", "usdc", "usdt"] as const;
type Asset = (typeof ASSETS)[number];

export function buildGetterSpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact, chain } = args;
  const chainKey = chain === "accounting" ? "accountingChain" : "earningChain";
  const chainConfig = (config[chainKey] ?? {}) as ChainConfig;
  const assets = (chainConfig.assets ?? {}) as Record<Asset, string>;

  const specs: GetterSpec[] = [];

  // -------- DepositPolicy (accounting only) --------
  if (chain === "accounting") {
    const depositPolicy = tryEntry(artefact, "DepositPolicy");
    const policy = ((chainConfig.depositPolicy ?? {}) as ChainConfig).perAssetLimits as
      | Record<Asset, { capacity: string | number; refillRate: string | number }>
      | undefined;
    if (depositPolicy && policy) {
      for (const asset of ASSETS) {
        const assetAddr = assets[asset];
        const limits = policy[asset];
        if (!assetAddr || !limits) continue;
        specs.push(
          bucketField(
            "DepositPolicy",
            `DepositPolicy.${asset}.capacity`,
            depositPolicy.address,
            DEPOSIT_POLICY_ABI as unknown as Abi,
            "getDepositLimit",
            [getAddress(assetAddr)],
            BigInt(limits.capacity),
            "capacity",
            "assetWei",
          ),
          bucketField(
            "DepositPolicy",
            `DepositPolicy.${asset}.refillRate`,
            depositPolicy.address,
            DEPOSIT_POLICY_ABI as unknown as Abi,
            "getDepositLimit",
            [getAddress(assetAddr)],
            BigInt(limits.refillRate),
            "refillRate",
            "assetWeiPerSec",
          ),
        );
      }
    }
  }

  // -------- FundsBridgingPolicy --------
  const fundsBridgingPolicy = tryEntry(artefact, "FundsBridgingPolicy");
  const remoteChainConfig =
    (config[chain === "accounting" ? "earningChain" : "accountingChain"] ?? {}) as ChainConfig;
  const remoteChainId = remoteChainConfig.chainId as number | string | undefined;
  const bridgingPolicy = ((chainConfig.fundsBridgingPolicy ?? {}) as ChainConfig).perAssetLimits as
    | Record<Asset, { capacity: string | number; refillRate: string | number }>
    | undefined;
  const ccipAdapter = tryEntry(artefact, "CcipAdapter");
  if (fundsBridgingPolicy && bridgingPolicy && remoteChainId !== undefined && ccipAdapter) {
    for (const asset of ASSETS) {
      const assetAddr = assets[asset];
      const limits = bridgingPolicy[asset];
      if (!assetAddr || !limits) continue;
      const args = [
        getAddress(assetAddr),
        BigInt(remoteChainId),
        ccipAdapter.address,
      ] as const;
      specs.push(
        bucketField(
          "FundsBridgingPolicy",
          `FundsBridgingPolicy.${asset}.via-ccip.capacity`,
          fundsBridgingPolicy.address,
          FUNDS_BRIDGING_POLICY_ABI as unknown as Abi,
          "getBridgingLimit",
          args,
          BigInt(limits.capacity),
          "capacity",
          "assetWei",
        ),
        bucketField(
          "FundsBridgingPolicy",
          `FundsBridgingPolicy.${asset}.via-ccip.refillRate`,
          fundsBridgingPolicy.address,
          FUNDS_BRIDGING_POLICY_ABI as unknown as Abi,
          "getBridgingLimit",
          args,
          BigInt(limits.refillRate),
          "refillRate",
          "assetWeiPerSec",
        ),
      );
    }
  }

  // -------- SlippageCoverageVault --------
  const slippageCoverageVault = tryEntry(artefact, "SlippageCoverageVault");
  const scvConfig = config.slippageCoverageVault as ChainConfig | undefined;
  if (slippageCoverageVault && scvConfig) {
    if (scvConfig.maxSlippageBps !== undefined) {
      specs.push({
        group: "SlippageCoverageVault",
        key: "SlippageCoverageVault.maxSlippageBps",
        address: slippageCoverageVault.address,
        abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
        functionName: "getMaxSlippageBps",
        expected: BigInt(scvConfig.maxSlippageBps as string | number),
        format: "bps",
      });
    }
    if (scvConfig.overrideMaxSlippageBps !== undefined) {
      specs.push({
        group: "SlippageCoverageVault",
        key: "SlippageCoverageVault.overrideMaxSlippageBps",
        address: slippageCoverageVault.address,
        abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
        functionName: "getOverrideMaxSlippageBps",
        expected: BigInt(scvConfig.overrideMaxSlippageBps as string | number),
        format: "bps",
      });
    }
    if (scvConfig.initialOverrideMode !== undefined) {
      specs.push({
        group: "SlippageCoverageVault",
        key: "SlippageCoverageVault.overrideMode",
        address: slippageCoverageVault.address,
        abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
        functionName: "getOverrideMode",
        expected: scvConfig.initialOverrideMode as boolean,
        format: "bool",
      });
    }
    const perAssetCaps = scvConfig.perAssetCaps as
      | Record<Asset, { pullCapPerTx: string | number; windowCap: string | number; windowSeconds: string | number }>
      | undefined;
    if (perAssetCaps) {
      for (const asset of ASSETS) {
        const assetAddr = assets[asset];
        const caps = perAssetCaps[asset];
        if (!assetAddr || !caps) continue;
        specs.push({
          group: "SlippageCoverageVault",
          key: `SlippageCoverageVault.${asset}.pullCapPerTx`,
          address: slippageCoverageVault.address,
          abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
          functionName: "getPullCapPerTx",
          args: [getAddress(assetAddr)],
          expected: BigInt(caps.pullCapPerTx),
          format: "assetWei",
        });
        specs.push({
          group: "SlippageCoverageVault",
          key: `SlippageCoverageVault.${asset}.windowCap`,
          address: slippageCoverageVault.address,
          abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
          functionName: "getWindow",
          args: [getAddress(assetAddr)],
          expected: BigInt(caps.windowCap),
          format: "assetWei",
          pick: (raw) => (raw as { cap: bigint }).cap,
        });
        specs.push({
          group: "SlippageCoverageVault",
          key: `SlippageCoverageVault.${asset}.windowSeconds`,
          address: slippageCoverageVault.address,
          abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
          functionName: "getWindow",
          args: [getAddress(assetAddr)],
          expected: BigInt(caps.windowSeconds),
          format: "seconds",
          pick: (raw) => BigInt((raw as { windowSeconds: number }).windowSeconds),
        });
      }
    }
  }

  // TODO(VA-229): AssetRegistry per-asset trusted/distrusted + deposit/swap flags.
  // TODO(VA-229): Allocator trusted strategies + per-asset strategy list (EC: sGHO).
  // TODO(VA-229): StableVault.{getTreasury, getDefaultSubVault, getMaxValidPerSecondRate}.
  // TODO(VA-229): WithdrawalExecutionPolicy.{getDefaultFeeBps, getRedemptionBucket, isSigner}.
  // TODO(VA-229): AccessManager role delays + profile assignments per role (driven from roles.json).
  // TODO(VA-229): PriceOracle adapter wiring per asset.
  // TODO(VA-229): ChainBalanceOracle adapter wiring per chain.
  // TODO(VA-229): BridgeAdapter whitelist enumeration.
  // TODO(VA-229): IouTokenManager.minBurnIouTokenGasLimit immutable.

  return specs;
}

function bucketField(
  group: string,
  key: string,
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[],
  expected: bigint,
  field: "capacity" | "refillRate",
  format: "assetWei" | "assetWeiPerSec",
): GetterSpec {
  return {
    group,
    key,
    address,
    abi,
    functionName,
    args,
    expected,
    format,
    pick: (raw) => (raw as Record<string, bigint>)[field]!,
  };
}
