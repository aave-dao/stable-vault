import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

interface ForgeArtifact {
  methodIdentifiers?: Record<string, string>;
}

/**
 * Returns the canonical Solidity function signature (e.g. `setUserRate((address,uint256)[])`) for a given
 * `(contractName, fourByteSelector)` pair, by reading the corresponding Forge build artifact in `out/`. Contracts and
 * interfaces share the same lookup pattern because Forge emits `methodIdentifiers` for both.
 */
export function loadSignatureLookup(outDir: string, contractsNeeded: Iterable<string>): Map<string, Map<string, string>> {
  const result = new Map<string, Map<string, string>>();
  for (const contract of new Set(contractsNeeded)) {
    const artifactPath = join(outDir, `${contract}.sol`, `${contract}.json`);
    if (!existsSync(artifactPath)) {
      throw new Error(`Missing Forge artifact: ${artifactPath} — run \`forge build\` first`);
    }
    const artifact = JSON.parse(readFileSync(artifactPath, "utf8")) as ForgeArtifact;
    const methodIdentifiers = artifact.methodIdentifiers ?? {};
    const sigBySelector = new Map<string, string>();
    for (const [sig, selectorHex] of Object.entries(methodIdentifiers)) {
      sigBySelector.set("0x" + selectorHex.toLowerCase(), sig);
    }
    result.set(contract, sigBySelector);
  }
  return result;
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
