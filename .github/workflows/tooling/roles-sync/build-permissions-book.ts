/**
 * Builds the two static artifacts the `aave-permissions-book` repo needs for its
 * `STABLE_VAULTS` pool, derived from `output/roles.json` (run `yarn roles:build` first):
 *
 *   1. `output/permissions-book/functionsPermissionsStableVaults.json`
 *      One entry per *target* contract (each `locations[]` member), listing every
 *      AccessManager-gated function with its signature. Supplies only the function
 *      names/signatures; the book resolves the live bindings itself.
 *
 *   2. `output/permissions-book/roleLabelsStableVaults.json`
 *      roleId → canonical role name (`roles[].key`), plus the three meta-roles.
 *      The AccessManager exposes no on-chain label getter, so role names must be
 *      supplied statically.
 *
 * Both files are copied into the book repo's `statics/`. They only go stale when
 * RolesConfig.sol adds or renames role-gated functions — regenerate and re-PR to
 * the book whenever this script's output differs from the book's copy.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

import type { RolesArtifact } from "./lib/types.js";

const REPO_ROOT = process.cwd();
const ROLES_JSON_PATH = join(REPO_ROOT, ".github/workflows/tooling/roles-sync/output/roles.json");
const OUT_DIR = join(REPO_ROOT, ".github/workflows/tooling/roles-sync/output/permissions-book");

/** Meta-roles wired by AccessManagerBaseSetup but not present in roles[] (function-derived roles only). */
const META_ROLE_LABELS: Record<string, string> = {
  "0": "ADMIN_ROLE",
  "1": "ADMIN_ROLE_GUARDIAN_ROLE",
  "2": "OPERATIONAL_ROLE_GUARDIAN_ROLE",
};

interface BookFunction {
  name: string;
  roles: string[];
  signature: string;
}

interface BookContract {
  contract: string;
  functions: BookFunction[];
}

function main(): void {
  const artifact = JSON.parse(readFileSync(ROLES_JSON_PATH, "utf8")) as RolesArtifact;

  // ---- 1. functionsPermissionsStableVaults.json -------------------------------
  // Group functions by *target* contract (locations), not by defining contract:
  // the book keys its selector→name lookup on the contract the binding targets.
  const byLocation = new Map<string, Map<string, BookFunction>>();
  for (const role of artifact.roles) {
    const name = role.signature.slice(0, role.signature.indexOf("("));
    for (const location of role.locations) {
      if (!byLocation.has(location)) byLocation.set(location, new Map());
      const fns = byLocation.get(location)!;
      if (!fns.has(role.selector)) {
        // "restricted" is a placeholder; the book fills in the real roleIds from
        // live on-chain data, so only the name/signature matter here.
        fns.set(role.selector, { name, roles: ["restricted"], signature: role.signature });
      }
    }
  }

  const contracts: BookContract[] = [...byLocation.keys()].sort().map((contract) => ({
    contract,
    functions: [...byLocation.get(contract)!.values()].sort((a, b) => a.name.localeCompare(b.name)),
  }));

  // ---- 2. roleLabelsStableVaults.json ------------------------------------------
  const roleLabels: Record<string, string> = { ...META_ROLE_LABELS };
  for (const role of artifact.roles) {
    const existing = roleLabels[role.roleId];
    if (existing && existing !== role.key) {
      throw new Error(`roleId collision: ${role.roleId} maps to both "${existing}" and "${role.key}"`);
    }
    roleLabels[role.roleId] = role.key;
  }
  const sortedLabels = Object.fromEntries(
    Object.entries(roleLabels).sort(([a], [b]) => (BigInt(a) < BigInt(b) ? -1 : 1)),
  );

  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(
    join(OUT_DIR, "functionsPermissionsStableVaults.json"),
    JSON.stringify(contracts, null, 2) + "\n",
  );
  writeFileSync(
    join(OUT_DIR, "roleLabelsStableVaults.json"),
    JSON.stringify(sortedLabels, null, 2) + "\n",
  );

  const fnCount = contracts.reduce((n, c) => n + c.functions.length, 0);
  console.log(
    `permissions-book statics written to ${OUT_DIR}: ` +
      `${contracts.length} contracts / ${fnCount} functions, ${Object.keys(sortedLabels).length} role labels`,
  );
}

main();
