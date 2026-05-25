// Shared types for the smoke harness. Re-exports Env from tools/roles to keep
// the source-of-truth for env identifiers in one place.

import type { Address, Hex } from "viem";

export type Env = "staging" | "preprod" | "prod";
export const ENVS: readonly Env[] = ["staging", "preprod", "prod"] as const;

export type ChainKind = "accounting" | "earning";
export const CHAIN_KINDS: readonly ChainKind[] = ["accounting", "earning"] as const;

/** A single contract entry in `deployments/<env>/v1/<chain>.json`. */
export interface ArtefactEntry {
  address: Address;
  saltSeed: string;
}

/** An entry from the aTokenVaults array. */
export interface ATokenVaultEntry {
  address: Address;
  assetSymbol: string;
}

/** Parsed deployment artefact. */
export interface DeploymentArtefact {
  entries: Map<string, ArtefactEntry>;
  aTokenVaults: ATokenVaultEntry[];
  rawPath: string;
  rawSha: Hex;
}

/** Severity of a single check. */
export type CheckSeverity = "pass" | "fail" | "warning" | "skipped" | "error";

/** Output format for a value alongside the on-chain reading. */
export type ValueFormat =
  | "raw"
  | "address"
  | "bool"
  | "bps"
  | "seconds"
  | "ray"
  | "rayPerSec"
  | "assetWei"
  | "assetWeiPerSec"
  | "uint"
  | "bytes32";

/** Structured result of a single check (topology, parity, or live probe). */
export interface CheckResult {
  group: string;
  key: string;
  severity: CheckSeverity;
  expected?: unknown;
  actual?: unknown;
  format?: ValueFormat;
  note?: string;
}

/** Metadata captured at the start of a run. */
export interface RunMeta {
  env: Env;
  chain: ChainKind;
  chainId: number;
  rpcUrlMasked: string;
  blockNumber: bigint;
  blockTimestamp: bigint;
  commit: string;
  configPath: string;
  configSha: Hex;
  artefactPath: string;
  artefactSha: Hex;
  startedAt: string;
}

/** Aggregate report written to JSON + summarised on stdout. */
export interface SmokeReport {
  meta: RunMeta;
  results: CheckResult[];
  summary: {
    total: number;
    pass: number;
    fail: number;
    warning: number;
    skipped: number;
    error: number;
    durationMs: number;
  };
}

/** CLI render mode. */
export type RenderMode = "full" | "summary" | "quiet" | "json";

/** Exit codes mapped from the smoke outcome. */
export const EXIT_CODES = {
  pass: 0,
  parityFail: 1,
  incompleteDeploy: 2,
  rpcError: 3,
  configError: 4,
} as const;
