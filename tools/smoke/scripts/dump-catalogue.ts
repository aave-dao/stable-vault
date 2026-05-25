// Print the parity catalogue size by group for a given (env, chain).
// Useful for confirming coverage before a deploy.
//
// Usage: npx tsx tools/smoke/scripts/dump-catalogue.ts <env> <chain>

import { readFileSync } from "node:fs";
import { parse as parseJsonc } from "jsonc-parser";

import { loadArtefact } from "../lib/artefact.js";
import { buildGetterSpecs } from "../lib/catalogue/getters.js";
import type { ChainKind, Env } from "../lib/types.js";

const env = (process.argv[2] ?? "preprod") as Env;
const chain = (process.argv[3] ?? "accounting") as ChainKind;
const REPO_ROOT = process.cwd();

const config = parseJsonc(readFileSync(`${REPO_ROOT}/config/deployment-config.${env}.jsonc`, "utf8")) as {
  deployer: `0x${string}`;
};
let artefact;
try {
  artefact = loadArtefact(env, chain, REPO_ROOT);
} catch (e) {
  process.stdout.write(`\n=== ${env} ${chain}: no artefact (${(e as Error).message.split(":").pop()?.trim()}) ===\n`);
  process.exit(0);
}
const specs = buildGetterSpecs({
  env,
  chain,
  config: config as unknown as Record<string, unknown>,
  artefact,
  deployer: config.deployer,
  repoRoot: REPO_ROOT,
});
const byGroup: Record<string, number> = {};
for (const s of specs) byGroup[s.group] = (byGroup[s.group] ?? 0) + 1;
process.stdout.write(`\n=== ${env} ${chain}: ${specs.length} specs ===\n`);
for (const [g, n] of Object.entries(byGroup).sort()) {
  process.stdout.write(`  ${g.padEnd(28)} ${n}\n`);
}
