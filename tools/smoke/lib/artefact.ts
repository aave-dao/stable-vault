// Load and index the deployment artefact written by BaseChainDeployment._logDeployment.
// Schema:
//   { "<Name>": { "address": "0x…", "saltSeed": "<seed-or-empty>" }, … "aTokenVaults": [...] }
// Implementation entries use the "::Implementation" suffix on the same JSON object.

import { readFileSync } from "node:fs";
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

export function artefactPath(env: Env, chain: ChainKind, repoRoot: string): string {
  // Matches deploymentOutputPath from config/deployment-config.<env>.jsonc.
  return resolve(repoRoot, `deployments/${env}/v1/${chain}.json`);
}

export function loadArtefact(env: Env, chain: ChainKind, repoRoot: string): DeploymentArtefact {
  const path = artefactPath(env, chain, repoRoot);
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
