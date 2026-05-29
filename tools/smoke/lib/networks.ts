// Single source of truth for the env → chains mapping. Loads
// tools/smoke/networks.json and resolves the (chain-kind, network) tuple plus
// the RPC env-var name for a given (env, kind, optional network) request.
//
// Convention: the RPC env var defaults to `SMOKE_RPC_<ENV>_<NETWORK>`
// (e.g. `SMOKE_RPC_STAGING_ARBITRUM`). A chain entry can override it via an
// explicit `rpcEnvVar` field. Network names live in lowercase in the JSON
// (`arbitrum`, `ethereum`, `base`, …); the convention upper-cases them.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { parse as parseJsonc } from "jsonc-parser";

import type { ChainKind, Env } from "./types.js";

export interface ChainEntry {
  kind: ChainKind;
  network: string;
  /** Optional override; otherwise defaults to `SMOKE_RPC_<ENV>_<NETWORK>`. */
  rpcEnvVar?: string;
}

export interface EnvEntry {
  rpcSource: "vnet" | "mainnet";
  chains: ChainEntry[];
}

export type NetworksFile = Record<string, EnvEntry>;

const NETWORKS_REL_PATH = "tools/smoke/networks.json";

export function loadNetworks(repoRoot: string): NetworksFile {
  const path = resolve(repoRoot, NETWORKS_REL_PATH);
  const raw = readFileSync(path, "utf8");
  return parseJsonc(raw) as NetworksFile;
}

export function getEnvEntry(networks: NetworksFile, env: Env): EnvEntry {
  const entry = networks[env];
  if (!entry) throw new Error(`networks.json: no entry for env "${env}"`);
  return entry;
}

/**
 * Resolve a chain entry given (env, kind, optional network). Errors out when
 * ambiguous (multiple chains of the same kind in this env, no network passed)
 * or when no chain matches.
 */
export function resolveChainEntry(
  networks: NetworksFile,
  env: Env,
  kind: ChainKind,
  network: string | undefined,
): ChainEntry {
  const envEntry = getEnvEntry(networks, env);
  const matchesKind = envEntry.chains.filter((c) => c.kind === kind);
  if (matchesKind.length === 0) {
    throw new Error(`networks.json: env "${env}" has no chain of kind "${kind}"`);
  }
  if (network !== undefined) {
    const match = matchesKind.find((c) => c.network === network);
    if (!match) {
      const available = matchesKind.map((c) => c.network).join(", ");
      throw new Error(
        `networks.json: env "${env}" kind "${kind}" has no network "${network}". Available: ${available}`,
      );
    }
    return match;
  }
  if (matchesKind.length === 1) return matchesKind[0]!;
  const available = matchesKind.map((c) => c.network).join(", ");
  throw new Error(
    `networks.json: env "${env}" has multiple "${kind}" chains; pass --network <name>. Available: ${available}`,
  );
}

export function defaultRpcEnvVar(env: Env, network: string): string {
  return `SMOKE_RPC_${env.toUpperCase()}_${network.toUpperCase()}`;
}

export function rpcEnvVarFor(env: Env, chain: ChainEntry): string {
  return chain.rpcEnvVar ?? defaultRpcEnvVar(env, chain.network);
}
