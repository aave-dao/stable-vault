import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

interface ForgeArtifact {
  methodIdentifiers?: Record<string, string>;
}

/**
 * Returns the canonical Solidity function signature (e.g. `setUserRate((address,uint256)[])`) for a given
 * `(contractName, fourByteSelector)` pair.
 *
 * Forge nests artifacts as `out/<sourceFile>.sol/<ContractName>.json`, may insert a parent-directory segment for
 * basename collisions (`out/interfaces/IFoo.sol/IFoo.json`), and may emit per-profile suffixed variants instead of an
 * un-suffixed `<ContractName>.json` when `additional_compiler_profiles` is in play. To handle all of these without
 * guessing, we first walk `out/` and pick the best artifact per contract name; if that still misses, we fall back to
 * `forge inspect <contract> methodIdentifiers --json`, which Foundry resolves authoritatively regardless of artifact
 * layout.
 */
export function loadSignatureLookup(outDir: string, contractsNeeded: Iterable<string>): Map<string, Map<string, string>> {
  const artifactPathsByContract = indexArtifactsByContract(outDir);
  const result = new Map<string, Map<string, string>>();
  for (const contract of new Set(contractsNeeded)) {
    const sigBySelector = loadFromArtifact(contract, artifactPathsByContract) ?? loadViaForgeInspect(contract);
    if (!sigBySelector) {
      const sample = [...artifactPathsByContract.keys()].sort().slice(0, 20).join(", ");
      throw new Error(
        `No methodIdentifiers found for ${contract}: not in out/ index (sample: ${sample}…) and \`forge inspect\` failed`,
      );
    }
    result.set(contract, sigBySelector);
  }
  return result;
}

function loadFromArtifact(contract: string, index: Map<string, string>): Map<string, string> | null {
  const path = index.get(contract);
  if (!path) return null;
  const artifact = JSON.parse(readFileSync(path, "utf8")) as ForgeArtifact;
  const methodIdentifiers = artifact.methodIdentifiers ?? {};
  if (Object.keys(methodIdentifiers).length === 0) return null;
  return buildSigMap(methodIdentifiers);
}

function loadViaForgeInspect(contract: string): Map<string, string> | null {
  try {
    const stdout = execFileSync("forge", ["inspect", contract, "methodIdentifiers", "--json"], {
      stdio: ["ignore", "pipe", "pipe"],
      encoding: "utf8",
    });
    const parsed = JSON.parse(stdout) as Record<string, string>;
    if (Object.keys(parsed).length === 0) return null;
    return buildSigMap(parsed);
  } catch {
    return null;
  }
}

function buildSigMap(methodIdentifiers: Record<string, string>): Map<string, string> {
  const out = new Map<string, string>();
  for (const [sig, selectorHex] of Object.entries(methodIdentifiers)) {
    const normalised = selectorHex.startsWith("0x") ? selectorHex.toLowerCase() : "0x" + selectorHex.toLowerCase();
    out.set(normalised, sig);
  }
  return out;
}

/**
 * Walks `out/` and returns a map of contract name → preferred artifact path. The "default" / un-suffixed artifact
 * (e.g. `IFoo.json`) wins over compiler-profile variants (`IFoo.default.json`, `IFoo.balanced.json`,
 * `IFoo.size-optimized.json`); the first match by directory-walk order wins among equally-named artifacts.
 */
function indexArtifactsByContract(outDir: string): Map<string, string> {
  const out = new Map<string, string>();
  walk(outDir, (path, name) => {
    if (!name.endsWith(".json")) return;
    if (name.endsWith(".dbg.json")) return;
    const stem = name.slice(0, -".json".length);
    if (stem.includes(".")) return;
    if (!out.has(stem)) out.set(stem, path);
  });
  return out;
}

function walk(root: string, visit: (path: string, name: string) => void): void {
  let entries: string[];
  try {
    entries = readdirSync(root);
  } catch {
    return;
  }
  for (const name of entries) {
    const path = join(root, name);
    let stat;
    try {
      stat = statSync(path);
    } catch {
      continue;
    }
    if (stat.isDirectory()) {
      walk(path, visit);
    } else {
      visit(path, name);
    }
  }
}

export function lookupSignature(
  sigsByContract: Map<string, Map<string, string>>,
  contract: string,
  selector: string,
): string {
  const sigsForContract = sigsByContract.get(contract);
  if (!sigsForContract) {
    throw new Error(`No signatures loaded for ${contract}`);
  }
  const sig = sigsForContract.get(selector.toLowerCase());
  if (sig) {
    return sig;
  }

  const inspected = loadViaForgeInspect(contract);
  if (inspected) {
    sigsByContract.set(contract, inspected);
    const inspectedSig = inspected.get(selector.toLowerCase());
    if (inspectedSig) {
      return inspectedSig;
    }
  }

  throw new Error(`Selector ${selector} not found in ${contract} methodIdentifiers`);
}
