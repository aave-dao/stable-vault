// Load and index the deployment artefact written by BaseChainDeployment._logDeployment.
// Schema:
//   { "<Name>": { "address": "0x…", "saltSeed": "<seed-or-empty>" }, … "aTokenVaults": [...] }
// Implementation entries use the "::Implementation" suffix on the same JSON object.

import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { getAddress, keccak256, toHex, type Address, type Hex } from "viem";

import type { ChainKind, DeploymentArtefact, ArtefactEntry, ATokenVaultEntry, Env } from "./types.js";

interface RawEntry {
  address?: string;
  saltSeed?: string;
}

interface RawATokenVault {
  address: string;
  assetSymbol: string;
}

/**
 * Resolve the deployment artefact path. Prefers `deployments/<env>/<network>.json`
 * when present (forward-compatible with multi-EC deploys writing per-network
 * artefacts), falling back to `deployments/<env>/<kind>.json` (today's
 * single-EC `earning.json` / `accounting.json` layout).
 */
export function artefactPath(env: Env, kind: ChainKind, network: string, repoRoot: string): string {
  const networkPath = resolve(repoRoot, `deployments/${env}/${network}.json`);
  if (existsSync(networkPath)) return networkPath;
  return resolve(repoRoot, `deployments/${env}/${kind}.json`);
}

export function loadArtefact(env: Env, kind: ChainKind, network: string, repoRoot: string): DeploymentArtefact {
  const path = artefactPath(env, kind, network, repoRoot);
  const raw = readFileSync(path, "utf8");
  const json = JSON.parse(raw) as Record<string, unknown>;

  const entries = new Map<string, ArtefactEntry>();
  const aTokenVaults: ATokenVaultEntry[] = [];

  for (const [name, value] of Object.entries(json)) {
    if (name === "aTokenVaults") {
      const arr = value as RawATokenVault[];
      for (const v of arr) {
        aTokenVaults.push({
          address: getAddress(v.address),
          assetSymbol: v.assetSymbol,
        });
      }
      continue;
    }
    const entry = value as RawEntry;
    if (!entry.address) continue;
    entries.set(name, {
      address: getAddress(entry.address),
      saltSeed: entry.saltSeed ?? "",
    });
  }

  return {
    entries,
    aTokenVaults,
    rawPath: path,
    rawSha: keccak256(toHex(raw)),
  };
}

/** Look up an entry, throwing a clear error if missing. */
export function requireEntry(artefact: DeploymentArtefact, name: string): ArtefactEntry {
  const entry = artefact.entries.get(name);
  if (!entry) {
    throw new Error(`Missing entry "${name}" in ${artefact.rawPath}`);
  }
  return entry;
}

/** Optional lookup; returns null when the contract is conditionally absent (e.g. AdiAdapter). */
export function tryEntry(artefact: DeploymentArtefact, name: string): ArtefactEntry | null {
  return artefact.entries.get(name) ?? null;
}

/** Implementation entry for a transparent proxy ("<Name>::Implementation"). */
export function implEntry(artefact: DeploymentArtefact, proxyName: string): ArtefactEntry | null {
  return artefact.entries.get(`${proxyName}::Implementation`) ?? null;
}
