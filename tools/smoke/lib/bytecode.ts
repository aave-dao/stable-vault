// Match a contract's on-chain runtime bytecode against the current Foundry build,
// tolerating the two differences that are expected even when the source is identical:
//   1. Immutables - solc writes constructor immutables into the runtime at deploy time,
//      but the artefact's deployedBytecode has those byte ranges as zeros. We mask the
//      ranges (from the artefact's `immutableReferences`) on both sides before comparing.
//   2. CBOR metadata - solc appends a trailing metadata hash (compiler version/settings/
//      source paths). We strip it so a logic-identical build still matches.
//
// This assumes the build IS the deployed source (the `master == deployed` invariant): smoke
// builds at the current checkout, so a genuine source change surfaces as a `mismatch`.
//
// Reads the Foundry artefact under out/<file>.sol/<name>.json; falls back to
// `forge inspect <name> deployedBytecode --json` (no immutableReferences in that path).

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// Deployment keys whose Solidity contract (and thus artefact filename) differs from the key.
// Without this the artefact lookup finds nothing and bytecode degrades to a "could not resolve"
// warning. (Both multicalls are instances of OwnedMulticall.)
const ARTEFACT_ALIAS: Record<string, string> = {
  DisablerMulticall: "OwnedMulticall",
  RebalancerMulticall: "OwnedMulticall",
};

export type BytecodeMatch =
  | { kind: "exact"; profile: string }
  | { kind: "immutables"; count: number; profile: string }
  | { kind: "metadata"; profile: string } // logic-identical; only the trailing CBOR metadata differs
  | { kind: "mismatch"; note: string }
  | { kind: "no-artifact" };

interface ImmutableRef {
  start: number;
  length: number;
}
interface ArtefactJson {
  deployedBytecode?: { object?: string; immutableReferences?: Record<string, ImmutableRef[]> };
}

interface Candidate {
  /** compiler profile this artefact was built in: "default" (1M runs), "balanced" (9k), … */
  profile: string;
  object: string;
  refs: Record<string, ImmutableRef[]>;
}

const cache = new Map<string, Candidate[]>();

/**
 * Compare `<name>`'s on-chain runtime bytecode against the current build, trying EVERY compiler-
 * profile variant Foundry emitted (<name>.json, <name>.balanced.json, …) as a candidate. A
 * contract deployed under any profile matches its variant, so we don't need to know or pin the
 * deploy's optimizer_runs. Returns the strongest tier across candidates:
 * exact > immutables (equal after masking immutable sites) > metadata (equal after also stripping
 * the CBOR trailer) > mismatch. `no-artifact` when the build output is unavailable.
 */
export function matchDeployedBytecode(name: string, onchain: string, repoRoot: string): BytecodeMatch {
  const baseName = name.split("::")[0]!;
  // Some deployment keys differ from the Solidity contract name; map to the real artefact.
  const lookupName = ARTEFACT_ALIAS[baseName] ?? baseName;
  const candidates = loadCandidates(lookupName, repoRoot);
  if (candidates.length === 0) return { kind: "no-artifact" };

  const on = strip0x(onchain).toLowerCase();
  let immutables: BytecodeMatch | null = null;
  let metadata: BytecodeMatch | null = null;
  const notes: string[] = [];

  for (const c of candidates) {
    const ax = strip0x(c.object).toLowerCase();
    if (on === ax) return { kind: "exact", profile: c.profile }; // strongest possible
    if (on.length === ax.length) {
      // The artefact already has zeros at immutable sites; mask both for safety.
      const onMasked = maskRanges(on, c.refs);
      const axMasked = maskRanges(ax, c.refs);
      if (onMasked === axMasked) {
        immutables ??= { kind: "immutables", count: Object.keys(c.refs).length, profile: c.profile };
        continue;
      }
      const onStripped = stripCborMetadata(onMasked);
      const axStripped = stripCborMetadata(axMasked);
      if (onStripped !== null && onStripped === axStripped) {
        metadata ??= { kind: "metadata", profile: c.profile };
        continue;
      }
    }
    notes.push(
      on.length !== ax.length
        ? `${c.profile}: length ${on.length / 2}B on-chain vs ${ax.length / 2}B`
        : `${c.profile}: differs at byte ${firstDiff(on, ax)}`,
    );
  }

  return immutables ?? metadata ?? { kind: "mismatch", note: notes.join("; ") };
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

function loadCandidates(name: string, repoRoot: string): Candidate[] {
  const cached = cache.get(name);
  if (cached) return cached;
  let candidates = readArtefactVariants(name, repoRoot);
  if (candidates.length === 0) candidates = readViaForgeInspect(name, repoRoot);
  cache.set(name, candidates);
  return candidates;
}

/**
 * Collect every artefact variant Foundry emitted for `<name>`: `<name>.json` (the default profile)
 * plus per-profile variants `<name>.<profile>.json` (e.g. `<name>.balanced.json`). They live in the
 * `<name>.sol` directory under out/.
 */
function readArtefactVariants(name: string, repoRoot: string): Candidate[] {
  const out: Candidate[] = [];
  for (const file of findArtefactFiles(join(repoRoot, "out"), name)) {
    try {
      const parsed = JSON.parse(readFileSync(file, "utf8")) as ArtefactJson;
      const obj = parsed.deployedBytecode?.object;
      if (!obj || obj === "0x") continue;
      out.push({ profile: profileFromFile(file, name), object: obj, refs: parsed.deployedBytecode?.immutableReferences ?? {} });
    } catch {
      // skip unreadable/!json variant
    }
  }
  return out;
}

/** Filenames are `<name>.json` (default) or `<name>.<profile>.json`. */
function profileFromFile(file: string, name: string): string {
  const base = file.slice(file.lastIndexOf("/") + 1); // basename
  const mid = base.slice(name.length + 1, base.length - ".json".length); // between "<name>." and ".json"
  return mid === "" ? "default" : mid;
}

function findArtefactFiles(root: string, name: string): string[] {
  const matches: string[] = [];
  const walk = (dir: string) => {
    try {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, e.name);
        if (e.isDirectory()) walk(full);
        // `<name>.json` and `<name>.<profile>.json`, but not `<nameOther>.json`.
        else if (e.name.startsWith(`${name}.`) && e.name.endsWith(".json") && statSync(full).isFile()) {
          matches.push(full);
        }
      }
    } catch {
      // out/ missing or unreadable - fall through to forge inspect
    }
  };
  walk(root);
  return matches;
}

function readViaForgeInspect(name: string, repoRoot: string): Candidate[] {
  try {
    const stdout = execFileSync("forge", ["inspect", name, "deployedBytecode", "--json"], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const parsed = JSON.parse(stdout) as { object?: string } | string;
    const obj = typeof parsed === "string" ? parsed : parsed.object;
    if (!obj || obj === "0x") return [];
    // forge inspect doesn't surface immutableReferences - masking unavailable on this path.
    return [{ profile: "inspect", object: obj, refs: {} }];
  } catch {
    return [];
  }
}
