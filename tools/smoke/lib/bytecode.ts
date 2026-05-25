// Resolve the expected runtime bytecode for a contract name by reading the
// Foundry artefact under out/<file>.sol/<name>.json. Falls back to
// `forge inspect <name> deployedBytecode --json` when the artefact path is
// non-trivial (case-sensitive FS, suffixed compiler profiles, etc.).
//
// Mirrors tools/roles/lib/load-signatures.ts walking strategy.

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { keccak256, type Hex } from "viem";

const cache = new Map<string, Hex>();

interface ArtefactJson {
  deployedBytecode?: { object?: string };
}

/**
 * Return the keccak256 hash of `<name>`'s deployed (runtime) bytecode as
 * produced by the current Foundry build. Throws if the contract can't be found.
 */
export function expectedRuntimeBytecodeHash(name: string, repoRoot: string): Hex {
  const cached = cache.get(name);
  if (cached) return cached;

  // Strip any "::Variant" suffix used in the deployment artefact for proxy impls.
  const baseName = name.split("::")[0]!;
  const code = readArtefactCode(baseName, repoRoot) ?? readViaForgeInspect(baseName, repoRoot);
  if (!code) {
    throw new Error(`Could not resolve deployedBytecode for "${baseName}" via out/ or forge inspect.`);
  }
  const hash = keccak256(code);
  cache.set(name, hash);
  return hash;
}

function readArtefactCode(name: string, repoRoot: string): Hex | null {
  const outDir = join(repoRoot, "out");
  const found = findArtefactFile(outDir, `${name}.json`);
  if (!found) return null;
  try {
    const raw = readFileSync(found, "utf8");
    const parsed = JSON.parse(raw) as ArtefactJson;
    const obj = parsed.deployedBytecode?.object;
    if (!obj || obj === "0x") return null;
    return obj as Hex;
  } catch {
    return null;
  }
}

function findArtefactFile(root: string, filename: string): string | null {
  try {
    const entries = readdirSync(root, { withFileTypes: true });
    for (const e of entries) {
      const full = join(root, e.name);
      if (e.isDirectory()) {
        const inner = findArtefactFile(full, filename);
        if (inner) return inner;
      } else if (e.name === filename) {
        if (statSync(full).isFile()) return full;
      }
    }
  } catch {
    // out/ missing or unreadable — fall through to forge inspect
  }
  return null;
}

function readViaForgeInspect(name: string, repoRoot: string): Hex | null {
  try {
    const stdout = execFileSync("forge", ["inspect", name, "deployedBytecode", "--json"], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const parsed = JSON.parse(stdout) as { object?: string } | string;
    const obj = typeof parsed === "string" ? parsed : parsed.object;
    if (!obj || obj === "0x") return null;
    return obj as Hex;
  } catch {
    return null;
  }
}
