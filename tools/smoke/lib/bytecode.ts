// Match a contract's on-chain runtime bytecode against the current Foundry build,
// tolerating the two differences that are expected even when the source is identical:
//   1. Immutables — solc writes constructor immutables into the runtime at deploy time,
//      but the artefact's deployedBytecode has those byte ranges as zeros. We mask the
//      ranges (from the artefact's `immutableReferences`) on both sides before comparing.
//   2. CBOR metadata — solc appends a trailing metadata hash (compiler version/settings/
//      source paths). We strip it so a logic-identical build still matches.
//
// This assumes the build IS the deployed source (the `master == deployed` invariant): smoke
// builds at the current checkout, so a genuine source change surfaces as a `mismatch`.
//
// Adapted from the stable-vault-dashboard bytecode matcher (immutable-masked / partial tiers).
// Reads the Foundry artefact under out/<file>.sol/<name>.json; falls back to
// `forge inspect <name> deployedBytecode --json` (no immutableReferences in that path).

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

export type BytecodeMatch =
  | { kind: "exact" }
  | { kind: "immutables"; count: number }
  | { kind: "metadata" } // logic-identical; only the trailing CBOR metadata differs
  | { kind: "mismatch"; note: string }
  | { kind: "no-artifact" };

interface ImmutableRef {
  start: number;
  length: number;
}
interface ArtefactJson {
  deployedBytecode?: { object?: string; immutableReferences?: Record<string, ImmutableRef[]> };
}

interface LoadedArtefact {
  object: string;
  refs: Record<string, ImmutableRef[]>;
}

const cache = new Map<string, LoadedArtefact | null>();

/**
 * Compare `<name>`'s on-chain runtime bytecode against the current build. Returns the strongest
 * tier: exact > immutables (equal after masking immutable sites) > metadata (equal after also
 * stripping the CBOR trailer) > mismatch. `no-artifact` when the build output is unavailable.
 */
export function matchDeployedBytecode(name: string, onchain: string, repoRoot: string): BytecodeMatch {
  const baseName = name.split("::")[0]!;
  const art = loadArtefact(baseName, repoRoot);
  if (!art) return { kind: "no-artifact" };

  const on = strip0x(onchain).toLowerCase();
  const ax = strip0x(art.object).toLowerCase();
  if (on === ax) return { kind: "exact" };

  if (on.length === ax.length) {
    // The artefact already has zeros at immutable sites; mask both for safety.
    const onMasked = maskRanges(on, art.refs);
    const axMasked = maskRanges(ax, art.refs);
    if (onMasked === axMasked) {
      return { kind: "immutables", count: Object.keys(art.refs).length };
    }
    const onStripped = stripCborMetadata(onMasked);
    const axStripped = stripCborMetadata(axMasked);
    if (onStripped !== null && onStripped === axStripped) {
      return { kind: "metadata" };
    }
  }

  const note =
    on.length !== ax.length
      ? `length ${on.length / 2}B on-chain vs ${ax.length / 2}B artefact`
      : `differs at byte ${firstDiff(on, ax)}`;
  return { kind: "mismatch", note };
}

// ---------- pure helpers (exported for unit tests) ----------

export function strip0x(s: string): string {
  return s.startsWith("0x") ? s.slice(2) : s;
}

/** Zero out the byte ranges named by solc's immutableReferences (offsets are in bytes). */
export function maskRanges(hex: string, refs: Record<string, ImmutableRef[]>): string {
  const chars = hex.split("");
  for (const ranges of Object.values(refs)) {
    for (const { start, length } of ranges) {
      for (let i = start * 2; i < (start + length) * 2 && i < chars.length; i++) chars[i] = "0";
    }
  }
  return chars.join("");
}

/** Strip the trailing solc CBOR metadata (length encoded in the final 2 bytes); null if implausible. */
export function stripCborMetadata(hex: string): string | null {
  if (hex.length < 4) return null;
  const mlen = parseInt(hex.slice(-4), 16);
  if (!Number.isFinite(mlen) || mlen < 10 || mlen > 120 || (mlen + 2) * 2 > hex.length) return null;
  return hex.slice(0, hex.length - (mlen + 2) * 2);
}

function firstDiff(a: string, b: string): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return Math.floor(i / 2);
  return Math.floor(n / 2);
}

// ---------- artefact loading ----------

function loadArtefact(name: string, repoRoot: string): LoadedArtefact | null {
  if (cache.has(name)) return cache.get(name)!;
  const loaded = readArtefact(name, repoRoot) ?? readViaForgeInspect(name, repoRoot);
  cache.set(name, loaded);
  return loaded;
}

function readArtefact(name: string, repoRoot: string): LoadedArtefact | null {
  const found = findArtefactFile(join(repoRoot, "out"), `${name}.json`);
  if (!found) return null;
  try {
    const parsed = JSON.parse(readFileSync(found, "utf8")) as ArtefactJson;
    const obj = parsed.deployedBytecode?.object;
    if (!obj || obj === "0x") return null;
    return { object: obj, refs: parsed.deployedBytecode?.immutableReferences ?? {} };
  } catch {
    return null;
  }
}

function findArtefactFile(root: string, filename: string): string | null {
  try {
    for (const e of readdirSync(root, { withFileTypes: true })) {
      const full = join(root, e.name);
      if (e.isDirectory()) {
        const inner = findArtefactFile(full, filename);
        if (inner) return inner;
      } else if (e.name === filename && statSync(full).isFile()) {
        return full;
      }
    }
  } catch {
    // out/ missing or unreadable — fall through to forge inspect
  }
  return null;
}

function readViaForgeInspect(name: string, repoRoot: string): LoadedArtefact | null {
  try {
    const stdout = execFileSync("forge", ["inspect", name, "deployedBytecode", "--json"], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const parsed = JSON.parse(stdout) as { object?: string } | string;
    const obj = typeof parsed === "string" ? parsed : parsed.object;
    if (!obj || obj === "0x") return null;
    // forge inspect doesn't surface immutableReferences — masking unavailable on this path.
    return { object: obj, refs: {} };
  } catch {
    return null;
  }
}
