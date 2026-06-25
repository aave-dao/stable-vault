// GETTER_SPECS: one entry per JSONC config leaf that becomes on-chain state.
// Pairs each leaf with the contract + getter that reads it back.
//
// Builders are split per-group for readability. Each builder returns
// GetterSpec[] and the catalogue composer concatenates them.

import { type Abi, type Address, getAddress } from "viem";

import { tryEntry } from "../artefact.js";
import { buildAccessSpecs } from "./access-from-roles.js";
import {
  ACCESS_MANAGER_ABI,
  ALLOCATOR_ABI,
  ASSET_REGISTRY_ABI,
  BASE_CHAIN_GATEWAY_ABI,
  CHAIN_BALANCE_ORACLE_ABI,
  DEPOSIT_POLICY_ABI,
  FUNDS_BRIDGING_POLICY_ABI,
  IOU_TOKEN_ABI,
  PRICE_ORACLE_ABI,
  SLIPPAGE_COVERAGE_VAULT_ABI,
  STABLE_VAULT_ABI,
  WITHDRAWAL_EXECUTION_POLICY_ABI,
} from "./abis.js";
import type { GetterSpec } from "../parity.js";
import type { ChainKind, DeploymentArtefact, Env } from "../types.js";

void ACCESS_MANAGER_ABI; // re-exported transitively via access-from-roles

type ChainConfig = Record<string, unknown>;

export interface BuildArgs {
  env: Env;
  chain: ChainKind;
  config: Record<string, unknown>;
  artefact: DeploymentArtefact;
  deployer: Address;
  repoRoot: string;
}

const ASSETS = ["gho", "usdc", "usdt"] as const;
type Asset = (typeof ASSETS)[number];

export function buildGetterSpecs(args: BuildArgs): GetterSpec[] {
  return [
    ...buildAssetRegistrySpecs(args),
    ...buildAllocatorSpecs(args),
    ...buildStableVaultSpecs(args),
    ...buildIouTokenSpecs(args),
    ...buildWithdrawalExecutionPolicySpecs(args),
    ...buildDepositPolicySpecs(args),
    ...buildFundsBridgingPolicySpecs(args),
    ...buildSlippageCoverageVaultSpecs(args),
    ...buildOracleWiringSpecs(args),
    ...buildBridgeAdapterSpecs(args),
    ...buildAccessSpecs(args),
  ];
}

// ---------- AssetRegistry ----------

function buildAssetRegistrySpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact, chain } = args;
  const assetRegistry = tryEntry(artefact, "AssetRegistry");
  if (!assetRegistry) return [];
  const chainConfig = (config[chainKey(chain)] ?? {}) as ChainConfig;
  const assets = (chainConfig.assets ?? {}) as Record<Asset, string>;
  const specs: GetterSpec[] = [];

  for (const asset of ASSETS) {
    const assetAddr = assets[asset];
    if (!assetAddr) continue;
    const addr = getAddress(assetAddr);
    specs.push({
      group: "AssetRegistry",
      key: `AssetRegistry.${asset}.registered`,
      address: assetRegistry.address,
      abi: ASSET_REGISTRY_ABI,
      functionName: "isAssetRegistered",
      args: [addr],
      expected: true,
      format: "bool",
    });
    specs.push({
      group: "AssetRegistry",
      key: `AssetRegistry.${asset}.trusted`,
      address: assetRegistry.address,
      abi: ASSET_REGISTRY_ABI,
      functionName: "isAssetTrusted",
      args: [addr],
      expected: true,
      format: "bool",
    });
    for (const field of [
      "depositFromUserAllowed",
      "depositIntoAllocatorAllowed",
      "swapInputTokenAllowed",
      "swapOutputTokenAllowed",
    ] as const) {
      specs.push({
        group: "AssetRegistry",
        key: `AssetRegistry.${asset}.${field}`,
        address: assetRegistry.address,
        abi: ASSET_REGISTRY_ABI,
        functionName: "getAssetConfig",
        args: [addr],
        expected: true,
        format: "bool",
        pick: (raw) => (raw as Record<string, boolean>)[field]!,
      });
    }
  }
  return specs;
}

// ---------- Allocator ----------

function buildAllocatorSpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact, chain } = args;
  const allocator = tryEntry(artefact, "Allocator");
  if (!allocator) return [];
  const chainConfig = (config[chainKey(chain)] ?? {}) as ChainConfig;
  const assets = (chainConfig.assets ?? {}) as Record<Asset, string>;
  const specs: GetterSpec[] = [];

  if (chain === "earning") {
    // EC: sGHO ERC-4626 strategies declared in JSONC; per-entry trust + per-asset registration.
    const strategies = (chainConfig.erc4626Strategies ?? []) as Array<{
      strategyAddress: string;
      underlyingAddress: string;
      strategySymbol: string;
    }>;
    for (const strat of strategies) {
      const stratAddr = getAddress(strat.strategyAddress);
      const underlyingAddr = getAddress(strat.underlyingAddress);
      specs.push({
        group: "Allocator",
        key: `Allocator.${strat.strategySymbol}.trusted`,
        address: allocator.address,
        abi: ALLOCATOR_ABI,
        functionName: "isStrategyTrusted",
        args: [stratAddr],
        expected: true,
        format: "bool",
      });
      specs.push({
        group: "Allocator",
        key: `Allocator.${strat.strategySymbol}.supportedForAsset`,
        address: allocator.address,
        abi: ALLOCATOR_ABI,
        functionName: "isStrategySupportedForAsset",
        args: [underlyingAddr, stratAddr],
        expected: true,
        format: "bool",
      });
    }
  }

  // aTokenVault strategies (both chains use them). Sourced from the deployment
  // artefact's aTokenVaults[] array — one entry per (assetSymbol, address).
  for (const vault of artefact.aTokenVaults) {
    const stratAddr = vault.address;
    const assetKey = vault.assetSymbol.toLowerCase() as Asset | string;
    const assetAddr = assets[assetKey as Asset];
    if (!assetAddr) continue;
    specs.push({
      group: "Allocator",
      key: `Allocator.aTokenVault.${vault.assetSymbol}.trusted`,
      address: allocator.address,
      abi: ALLOCATOR_ABI,
      functionName: "isStrategyTrusted",
      args: [stratAddr],
      expected: true,
      format: "bool",
    });
    specs.push({
      group: "Allocator",
      key: `Allocator.aTokenVault.${vault.assetSymbol}.supportedForAsset`,
      address: allocator.address,
      abi: ALLOCATOR_ABI,
      functionName: "isStrategySupportedForAsset",
      args: [getAddress(assetAddr), stratAddr],
      expected: true,
      format: "bool",
    });
  }

  return specs;
}

// ---------- StableVault (accounting chain only) ----------

function buildStableVaultSpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact, chain } = args;
  if (chain !== "accounting") return [];
  const stableVault = tryEntry(artefact, "StableVault");
  if (!stableVault) return [];
  const ac = (config.accountingChain ?? {}) as ChainConfig;
  const specs: GetterSpec[] = [];

  // Treasury address may be initially zero (set later). Check exact match with config when set.
  // Note: JSONC has no `treasury` field today — it's set post-deploy. Track via skipIf.
  specs.push({
    group: "StableVault",
    key: "StableVault.treasury",
    address: stableVault.address,
    abi: STABLE_VAULT_ABI,
    functionName: "getTreasury",
    expected: "0x0000000000000000000000000000000000000000",
    format: "address",
    skipIf: { reason: "treasury is set post-deploy; check after first claimSurplusInterest config" },
  });

  if (ac.defaultMaxPerSecondRate !== undefined) {
    specs.push({
      group: "StableVault",
      key: "StableVault.maxValidPerSecondRate",
      address: stableVault.address,
      abi: STABLE_VAULT_ABI,
      functionName: "getMaxValidPerSecondRate",
      expected: BigInt(ac.defaultMaxPerSecondRate as string | number),
      format: "rayPerSec",
    });
  }
  if (ac.defaultSubVaultPerSecondRate !== undefined) {
    specs.push({
      group: "StableVault",
      key: "StableVault.defaultSubVault.perSecondRate",
      address: stableVault.address,
      abi: STABLE_VAULT_ABI,
      functionName: "getDefaultSubVault",
      expected: BigInt(ac.defaultSubVaultPerSecondRate as string | number),
      format: "rayPerSec",
      pick: (raw) => (raw as { perSecondRate: bigint }).perSecondRate,
    });
  }
  if (ac.stableVaultName !== undefined) {
    specs.push({
      group: "StableVault",
      key: "StableVault.name",
      address: stableVault.address,
      abi: STABLE_VAULT_ABI,
      functionName: "name",
      expected: ac.stableVaultName as string,
      format: "raw",
    });
  }
  if (ac.stableVaultSymbol !== undefined) {
    specs.push({
      group: "StableVault",
      key: "StableVault.symbol",
      address: stableVault.address,
      abi: STABLE_VAULT_ABI,
      functionName: "symbol",
      expected: ac.stableVaultSymbol as string,
      format: "raw",
    });
  }
  return specs;
}

// ---------- IouToken (accounting chain only — canonical IOU token) ----------

function buildIouTokenSpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact, chain } = args;
  if (chain !== "accounting") return [];
  const iouToken = tryEntry(artefact, "IouToken");
  if (!iouToken) return [];
  const specs: GetterSpec[] = [];

  if (config.iouTokenName !== undefined) {
    specs.push({
      group: "IouToken",
      key: "IouToken.name",
      address: iouToken.address,
      abi: IOU_TOKEN_ABI,
      functionName: "name",
      expected: config.iouTokenName as string,
      format: "raw",
    });
  }
  if (config.iouTokenSymbol !== undefined) {
    specs.push({
      group: "IouToken",
      key: "IouToken.symbol",
      address: iouToken.address,
      abi: IOU_TOKEN_ABI,
      functionName: "symbol",
      expected: config.iouTokenSymbol as string,
      format: "raw",
    });
  }
  return specs;
}

// ---------- WithdrawalExecutionPolicy ----------

function buildWithdrawalExecutionPolicySpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact, chain } = args;
  const wep = tryEntry(artefact, "WithdrawalExecutionPolicy") ?? tryEntry(artefact, "WithdrawalPolicy");
  if (!wep) return [];
  const wepConfig = (config.withdrawalExecutionPolicy ?? {}) as ChainConfig;
  const chainConfig = (config[chainKey(chain)] ?? {}) as ChainConfig;
  const redemption = ((chainConfig.withdrawalExecutionPolicy ?? {}) as ChainConfig).redemptionLimit as
    | { capacityRay: string | number; refillRateRay: string | number }
    | undefined;
  const specs: GetterSpec[] = [];

  if (wepConfig.defaultFeeBps !== undefined) {
    specs.push({
      group: "WithdrawalExecutionPolicy",
      key: "WithdrawalExecutionPolicy.defaultFeeBps",
      address: wep.address,
      abi: WITHDRAWAL_EXECUTION_POLICY_ABI,
      functionName: "getDefaultFeeBps",
      expected: BigInt(wepConfig.defaultFeeBps as string | number),
      format: "bps",
    });
  }
  if (wepConfig.signer !== undefined && wepConfig.signer !== "0x0000000000000000000000000000000000000000") {
    specs.push({
      group: "WithdrawalExecutionPolicy",
      key: "WithdrawalExecutionPolicy.signer",
      address: wep.address,
      abi: WITHDRAWAL_EXECUTION_POLICY_ABI,
      functionName: "isSigner",
      args: [getAddress(wepConfig.signer as string)],
      expected: true,
      format: "bool",
    });
  }
  if (redemption && redemption.capacityRay !== "TBD") {
    specs.push({
      group: "WithdrawalExecutionPolicy",
      key: "WithdrawalExecutionPolicy.redemptionBucket.capacity",
      address: wep.address,
      abi: WITHDRAWAL_EXECUTION_POLICY_ABI,
      functionName: "getRedemptionBucket",
      expected: BigInt(redemption.capacityRay),
      format: "ray",
      pick: (raw) => (raw as { capacity: bigint }).capacity,
    });
    specs.push({
      group: "WithdrawalExecutionPolicy",
      key: "WithdrawalExecutionPolicy.redemptionBucket.refillRate",
      address: wep.address,
      abi: WITHDRAWAL_EXECUTION_POLICY_ABI,
      functionName: "getRedemptionBucket",
      expected: BigInt(redemption.refillRateRay),
      format: "rayPerSec",
      pick: (raw) => (raw as { refillRate: bigint }).refillRate,
    });
  }
  const chainWep = (chainConfig.withdrawalExecutionPolicy ?? {}) as ChainConfig;
  if (chainWep.minRedemptionCapacityRay !== undefined && chainWep.minRedemptionCapacityRay !== "TBD") {
    specs.push({
      group: "WithdrawalExecutionPolicy",
      key: "WithdrawalExecutionPolicy.minRedemptionCapacity",
      address: wep.address,
      abi: WITHDRAWAL_EXECUTION_POLICY_ABI,
      functionName: "getMinRedemptionCapacity",
      expected: BigInt(chainWep.minRedemptionCapacityRay as string | number),
      format: "ray",
    });
  }
  if (chainWep.minRedemptionRefillRateRay !== undefined && chainWep.minRedemptionRefillRateRay !== "TBD") {
    specs.push({
      group: "WithdrawalExecutionPolicy",
      key: "WithdrawalExecutionPolicy.minRedemptionRefillRate",
      address: wep.address,
      abi: WITHDRAWAL_EXECUTION_POLICY_ABI,
      functionName: "getMinRedemptionRefillRate",
      expected: BigInt(chainWep.minRedemptionRefillRateRay as string | number),
      format: "rayPerSec",
    });
  }
  return specs;
}

// ---------- DepositPolicy (accounting chain only) ----------

function buildDepositPolicySpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact, chain } = args;
  if (chain !== "accounting") return [];
  const depositPolicy = tryEntry(artefact, "DepositPolicy");
  if (!depositPolicy) return [];
  const ac = (config.accountingChain ?? {}) as ChainConfig;
  const assets = (ac.assets ?? {}) as Record<Asset, string>;
  const policy = ((ac.depositPolicy ?? {}) as ChainConfig).perAssetLimits as
    | Record<Asset, { capacity: string | number; refillRate: string | number }>
    | undefined;
  if (!policy) return [];
  const specs: GetterSpec[] = [];
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
  return specs;
}

// ---------- FundsBridgingPolicy ----------

function buildFundsBridgingPolicySpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact, chain } = args;
  const fbp = tryEntry(artefact, "FundsBridgingPolicy");
  if (!fbp) return [];
  const chainConfig = (config[chainKey(chain)] ?? {}) as ChainConfig;
  const remoteConfig = (config[chainKey(otherChain(chain))] ?? {}) as ChainConfig;
  const assets = (chainConfig.assets ?? {}) as Record<Asset, string>;
  const bridging = ((chainConfig.fundsBridgingPolicy ?? {}) as ChainConfig).perAssetLimits as
    | Record<Asset, { capacity: string | number; refillRate: string | number }>
    | undefined;
  const ccipAdapter = tryEntry(artefact, "CcipAdapter");
  const remoteChainId = remoteConfig.chainId as number | string | undefined;
  if (!bridging || !ccipAdapter || remoteChainId === undefined) return [];

  const specs: GetterSpec[] = [];
  for (const asset of ASSETS) {
    const assetAddr = assets[asset];
    const limits = bridging[asset];
    if (!assetAddr || !limits) continue;
    const a = [getAddress(assetAddr), BigInt(remoteChainId), ccipAdapter.address] as const;
    specs.push(
      bucketField(
        "FundsBridgingPolicy",
        `FundsBridgingPolicy.${asset}.via-ccip.capacity`,
        fbp.address,
        FUNDS_BRIDGING_POLICY_ABI as unknown as Abi,
        "getBridgingLimit",
        a,
        BigInt(limits.capacity),
        "capacity",
        "assetWei",
      ),
      bucketField(
        "FundsBridgingPolicy",
        `FundsBridgingPolicy.${asset}.via-ccip.refillRate`,
        fbp.address,
        FUNDS_BRIDGING_POLICY_ABI as unknown as Abi,
        "getBridgingLimit",
        a,
        BigInt(limits.refillRate),
        "refillRate",
        "assetWeiPerSec",
      ),
    );
  }
  return specs;
}

// ---------- SlippageCoverageVault ----------

function buildSlippageCoverageVaultSpecs(args: BuildArgs): GetterSpec[] {
  const { config, artefact } = args;
  const scv = tryEntry(artefact, "SlippageCoverageVault");
  if (!scv) return [];
  const scvConfig = config.slippageCoverageVault as ChainConfig | undefined;
  if (!scvConfig) return [];
  const specs: GetterSpec[] = [];

  if (scvConfig.maxSlippageBps !== undefined) {
    specs.push({
      group: "SlippageCoverageVault",
      key: "SlippageCoverageVault.maxSlippageBps",
      address: scv.address,
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
      address: scv.address,
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
      address: scv.address,
      abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
      functionName: "getOverrideMode",
      expected: scvConfig.initialOverrideMode as boolean,
      format: "bool",
    });
  }
  const chainConfig = (config[chainKey(args.chain)] ?? {}) as ChainConfig;
  const assets = (chainConfig.assets ?? {}) as Record<Asset, string>;
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
        address: scv.address,
        abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
        functionName: "getPullCapPerTx",
        args: [getAddress(assetAddr)],
        expected: BigInt(caps.pullCapPerTx),
        format: "assetWei",
      });
      specs.push({
        group: "SlippageCoverageVault",
        key: `SlippageCoverageVault.${asset}.windowCap`,
        address: scv.address,
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
        address: scv.address,
        abi: SLIPPAGE_COVERAGE_VAULT_ABI as unknown as Abi,
        functionName: "getWindow",
        args: [getAddress(assetAddr)],
        expected: BigInt(caps.windowSeconds),
        format: "seconds",
        pick: (raw) => BigInt((raw as { windowSeconds: number }).windowSeconds),
      });
    }
  }
  return specs;
}

// ---------- Oracle wiring (PriceOracle adapter per asset, ChainBalanceOracle adapter per chain) ----------

function buildOracleWiringSpecs(args: BuildArgs): GetterSpec[] {
  const { artefact, config, chain } = args;
  const priceOracle = tryEntry(artefact, "PriceOracle");
  const specs: GetterSpec[] = [];

  if (priceOracle) {
    const chainConfig = (config[chainKey(chain)] ?? {}) as ChainConfig;
    const assets = (chainConfig.assets ?? {}) as Record<Asset, string>;
    const adapterPrefix =
      chain === "accounting" ? "ChainlinkL2PriceOracleAdapter" : "ChainlinkPriceOracleAdapter";
    for (const asset of ASSETS) {
      const assetAddr = assets[asset];
      if (!assetAddr) continue;
      const adapterEntry = tryEntry(artefact, `${adapterPrefix}::${asset.toUpperCase()}`);
      if (!adapterEntry) continue;
      specs.push({
        group: "Oracles",
        key: `PriceOracle.adapter.${asset}`,
        address: priceOracle.address,
        abi: PRICE_ORACLE_ABI,
        functionName: "getOracleAdapterForAsset",
        args: [getAddress(assetAddr)],
        expected: adapterEntry.address,
        format: "address",
      });
    }
  }

  if (chain === "accounting") {
    const chainBalanceOracle = tryEntry(artefact, "ChainBalanceOracle");
    const ec = (config.earningChain ?? {}) as ChainConfig;
    const ecChainId = ec.chainId as number | string | undefined;
    const adapterEntry = tryEntry(artefact, "ChainlinkL2ChainBalanceOracleAdapter")
      ?? tryEntry(artefact, "ChainlinkChainBalanceOracleAdapter");
    if (chainBalanceOracle && adapterEntry && ecChainId !== undefined) {
      specs.push({
        group: "Oracles",
        key: `ChainBalanceOracle.adapter.${ecChainId}`,
        address: chainBalanceOracle.address,
        abi: CHAIN_BALANCE_ORACLE_ABI,
        functionName: "getChainBalanceOracleAdapter",
        args: [BigInt(ecChainId)],
        expected: adapterEntry.address,
        format: "address",
      });
    }
  }
  return specs;
}

// ---------- Bridge adapters whitelist enumeration ----------

function buildBridgeAdapterSpecs(args: BuildArgs): GetterSpec[] {
  const { artefact, config, chain } = args;
  const gateway = chain === "accounting"
    ? tryEntry(artefact, "AccountingChainGateway")
    : tryEntry(artefact, "EarningChainGateway");
  if (!gateway) return [];
  const chainConfig = (config[chainKey(chain)] ?? {}) as ChainConfig;
  const remoteConfig = (config[chainKey(otherChain(chain))] ?? {}) as ChainConfig;
  const remoteChainId = remoteConfig.chainId as number | string | undefined;
  const assets = (chainConfig.assets ?? {}) as Record<Asset, string>;
  const ccipAdapter = tryEntry(artefact, "CcipAdapter");
  const adiAdapter = tryEntry(artefact, "AdiAdapter");
  const adiConfig = (chainConfig.adi ?? {}) as { registerOnGateway?: boolean };
  if (remoteChainId === undefined) return [];

  const specs: GetterSpec[] = [];
  const adapters: Array<{ name: string; addr: Address; conditional: boolean; reason?: string }> = [];
  if (ccipAdapter) adapters.push({ name: "CcipAdapter", addr: ccipAdapter.address, conditional: false });
  if (adiAdapter && adiConfig.registerOnGateway) {
    adapters.push({ name: "AdiAdapter", addr: adiAdapter.address, conditional: false });
  } else if (adiAdapter) {
    adapters.push({
      name: "AdiAdapter",
      addr: adiAdapter.address,
      conditional: true,
      reason: "AdiAdapter present but adi.registerOnGateway=false; skip whitelist check",
    });
  }

  for (const adapter of adapters) {
    for (const asset of ASSETS) {
      const assetAddr = assets[asset];
      if (!assetAddr) continue;
      const key = `${gateway === tryEntry(artefact, "AccountingChainGateway") ? "AccountingChainGateway" : "EarningChainGateway"}.${adapter.name}.${asset}`;
      specs.push({
        group: "BridgeAdapters",
        key,
        address: gateway.address,
        abi: BASE_CHAIN_GATEWAY_ABI,
        functionName: "isFundsBridgeAdapterSupported",
        args: [getAddress(assetAddr), BigInt(remoteChainId), adapter.addr],
        expected: true,
        format: "bool",
        ...(adapter.conditional ? { skipIf: { reason: adapter.reason! } } : {}),
      });
    }
  }

  // Data-only adapter lifecycle. Per `BaseChainDeployment._setupBridgeAdapters`, only AdiAdapter is registered
  // as a data-only adapter (and only when adi.registerOnGateway = true); CcipAdapter is funds-only. Assert each
  // registered data-only adapter is in mode SEND_AND_RECEIVE (1) with no removal initiated (removalId = 0).
  const SEND_AND_RECEIVE = 1;
  const ZERO_BYTES32 = `0x${"0".repeat(64)}` as const;
  const dataOnlyAdapters: Array<{ name: string; addr: Address }> = [];
  if (adiAdapter && adiConfig.registerOnGateway) {
    dataOnlyAdapters.push({ name: "AdiAdapter", addr: adiAdapter.address });
  }
  const gatewayLabel =
    gateway === tryEntry(artefact, "AccountingChainGateway") ? "AccountingChainGateway" : "EarningChainGateway";
  for (const adapter of dataOnlyAdapters) {
    specs.push({
      group: "BridgeAdapters",
      key: `${gatewayLabel}.${adapter.name}.dataOnlyMode`,
      address: gateway.address,
      abi: BASE_CHAIN_GATEWAY_ABI,
      functionName: "getDataOnlyBridgeAdapterMode",
      args: [BigInt(remoteChainId), adapter.addr],
      expected: SEND_AND_RECEIVE,
      format: "uint",
    });
    specs.push({
      group: "BridgeAdapters",
      key: `${gatewayLabel}.${adapter.name}.dataOnlyRemovalId`,
      address: gateway.address,
      abi: BASE_CHAIN_GATEWAY_ABI,
      functionName: "getDataOnlyBridgeAdapterRemovalId",
      args: [BigInt(remoteChainId), adapter.addr],
      expected: ZERO_BYTES32,
      format: "bytes32",
    });
  }
  return specs;
}

// ---------- Helpers ----------

function chainKey(chain: ChainKind): "accountingChain" | "earningChain" {
  return chain === "accounting" ? "accountingChain" : "earningChain";
}

function otherChain(chain: ChainKind): ChainKind {
  return chain === "accounting" ? "earning" : "accounting";
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
