import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

interface ForgeArtifact {
  methodIdentifiers?: Record<string, string>;
}

/**
 * Returns the canonical Solidity function signature (e.g. `setUserRate((address,uint256)[])`) for a given
 * `(contractName, fourByteSelector)` pair, by reading Forge build artifacts under `out/`.
 *
 * Forge nests artifacts as `out/<sourceFile>.sol/<ContractName>.json`, and when two source files share a basename it
 * disambiguates by inserting a parent-directory segment (e.g. `out/interfaces/IFoo.sol/IFoo.json`). On case-sensitive
 * filesystems (Linux CI) this happens for `lib/aave-vault/src/interfaces/IATokenVaultMerklRewardClaimer.sol`; on
 * case-insensitive macOS the collision is silently coalesced into the flat path. To stay correct on both, we walk
 * `out/` once and index every artifact by its filename stem.
 */
export function loadSignatureLookup(outDir: string, contractsNeeded: Iterable<string>): Map<string, Map<string, string>> {
  const artifactPathsByContract = indexArtifactsByContract(outDir);
  const result = new Map<string, Map<string, string>>();
  for (const contract of new Set(contractsNeeded)) {
    const path = artifactPathsByContract.get(contract);
    if (!path) {
      throw new Error(`Missing Forge artifact for ${contract} under ${outDir} — run \`forge build\` first`);
    }
    const artifact = JSON.parse(readFileSync(path, "utf8")) as ForgeArtifact;
    const sigBySelector = new Map<string, string>();
    for (const [sig, selectorHex] of Object.entries(artifact.methodIdentifiers ?? {})) {
      sigBySelector.set("0x" + selectorHex.toLowerCase(), sig);
    }
    result.set(contract, sigBySelector);
  }
  return result;
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
  const entries = readdirSync(root);
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
  if (!sig) {
    throw new Error(`Selector ${selector} not found in ${contract} methodIdentifiers`);
  }
  return sig;
}
