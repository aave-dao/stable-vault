/**
 * Builds `script/output/roles.json` — the canonical, env-aware view of the access-control catalogue. The artifact is
 * derived from three independently parseable inputs and is the single source of truth that downstream consumers
 * (validation, Notion sync, audits) read.
 *
 * Pipeline:
 *   1. Three Forge dumps (`script/output/roles.dump.{staging,preprod,prod}.json`), one per env.
 *   2. `script/base/RolesConfig.sol`            → natspec, selector source, getAllFunctionBasedRoles ordering.
 *   3. `script/base/AccessManager*Setup.sol`    → profile → role grants, guardian-role membership.
 *   4. `config/deployment-config.*.jsonc`       → per-env profile addresses.
 *   5. `out/<Contract>.sol/<Contract>.json`     → canonical function signatures via methodIdentifiers.
 *
 * Output schema is the `RolesArtifact` defined in `tools/roles/lib/types.ts`.
 */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { loadSignatureLookup, lookupSignature } from "./lib/load-signatures.js";
import { parseGetAllFunctionBasedRolesOrder, parseProfiles, parseRolesConfig } from "./lib/parse-solidity.js";
import {
  DELAY_TIER_NAMES,
  ENVS,
  type DelayTierName,
  type DelayTierJson,
  type Env,
  type ForgeDump,
  type GuardianName,
  type ProfileGrants,
  type ProfileJson,
  type RoleJson,
  type RolesArtifact,
} from "./lib/types.js";

const REPO_ROOT = process.cwd();

const ROLES_CONFIG_PATH = join(REPO_ROOT, "script/base/RolesConfig.sol");
const ACCESS_MANAGER_PATHS = [
  join(REPO_ROOT, "script/base/AccessManagerBaseSetup.sol"),
  join(REPO_ROOT, "script/base/AccessManagerAccountingChainSetup.sol"),
  join(REPO_ROOT, "script/base/AccessManagerEarningChainSetup.sol"),
];
const FORGE_OUT_DIR = join(REPO_ROOT, "out");
const OUT_PATH = join(REPO_ROOT, "script/output/roles.json");

function main(): void {
  const natspec = parseRolesConfig(ROLES_CONFIG_PATH);
  const order = parseGetAllFunctionBasedRolesOrder(ROLES_CONFIG_PATH);
  const profiles = parseProfiles(ACCESS_MANAGER_PATHS);
  const dumps = loadDumps();

  assertDumpsAgreeOnShape(dumps, order);
  assertProfileSetMatches(profiles, dumps.staging);

  const contractsNeeded = new Set<string>();
  for (const fn of order) {
    const meta = natspec.get(fn);
    if (!meta) throw new Error(`No natspec entry for ${fn}`);
    contractsNeeded.add(meta.selectorSourceContract);
  }
  const signatures = loadSignatureLookup(FORGE_OUT_DIR, contractsNeeded);

  const grantsByGetRoleFn = invertProfileGrants(profiles, order);

  const delayTiers = buildDelayTiers(dumps);
  const profilesJson = buildProfiles(profiles, dumps);
  const roles = buildRoles({
    order,
    natspec,
    dumps,
    grantsByGetRoleFn,
    signatures,
  });

  const artifact: RolesArtifact = {
    source: {
      rolesConfigSha: sha256OfFile(ROLES_CONFIG_PATH),
      accessManagerBaseSetupSha: sha256OfFile(ACCESS_MANAGER_PATHS[0] ?? ""),
      accessManagerAccountingChainSetupSha: sha256OfFile(ACCESS_MANAGER_PATHS[1] ?? ""),
      accessManagerEarningChainSetupSha: sha256OfFile(ACCESS_MANAGER_PATHS[2] ?? ""),
    },
    delayTiers,
    profiles: profilesJson,
    roles,
  };

  writeFileSync(OUT_PATH, JSON.stringify(artifact, null, 2) + "\n");
  console.log(`Wrote ${roles.length} roles, ${profilesJson.length} profiles, ${delayTiers.length} delay tiers → ${OUT_PATH}`);
}

function loadDumps(): Record<Env, ForgeDump> {
  const out = {} as Record<Env, ForgeDump>;
  for (const env of ENVS) {
    const path = join(REPO_ROOT, `script/output/roles.dump.${env}.json`);
    out[env] = JSON.parse(readFileSync(path, "utf8")) as ForgeDump;
  }
  return out;
}

function assertDumpsAgreeOnShape(dumps: Record<Env, ForgeDump>, order: string[]): void {
  const reference = dumps.staging;
  if (reference.roles.length !== order.length) {
    throw new Error(
      `Forge dump (${reference.roles.length} roles) vs RolesConfig source (${order.length}) disagree on role count`,
    );
  }
  for (const env of ENVS) {
    const dump = dumps[env];
    if (dump.roles.length !== reference.roles.length) {
      throw new Error(`Dump ${env} has ${dump.roles.length} roles, expected ${reference.roles.length}`);
    }
    for (let i = 0; i < reference.roles.length; i++) {
      const ref = reference.roles[i]!;
      const cur = dump.roles[i]!;
      if (ref.selector !== cur.selector) {
        throw new Error(`Dump ${env}: selector mismatch at index ${i} (${cur.selector} vs ${ref.selector})`);
      }
      if (ref.roleId !== cur.roleId) {
        throw new Error(`Dump ${env}: roleId mismatch at index ${i} (${cur.roleId} vs ${ref.roleId})`);
      }
      if (ref.criticalRisk !== cur.criticalRisk) {
        throw new Error(`Dump ${env}: criticalRisk mismatch at index ${i}`);
      }
      if (ref.guardianRoleId !== cur.guardianRoleId) {
        throw new Error(`Dump ${env}: guardianRoleId mismatch at index ${i}`);
      }
    }
  }
}

function buildDelayTiers(dumps: Record<Env, ForgeDump>): DelayTierJson[] {
  return DELAY_TIER_NAMES.map((name) => ({
    name,
    secondsByEnv: ENVS.reduce(
      (acc, env) => {
        acc[env] = delaySecondsFor(name, dumps[env]);
        return acc;
      },
      {} as Record<Env, number>,
    ),
  }));
}

function delaySecondsFor(name: DelayTierName, dump: ForgeDump): number {
  switch (name) {
    case "NO_DELAY":
      return 0;
    case "LOW":
      return dump.lowDelaySeconds;
    case "MEDIUM":
      return dump.mediumDelaySeconds;
    case "HIGH":
      return dump.highDelaySeconds;
    case "CRITICAL":
      return dump.criticalDelaySeconds;
  }
}

function buildProfiles(profiles: Map<string, ProfileGrants>, dumps: Record<Env, ForgeDump>): ProfileJson[] {
  const out: ProfileJson[] = [];
  for (const [name, grants] of profiles) {
    const holdsGuardians: GuardianName[] = [];
    if (grants.holdsAdminGuardian) holdsGuardians.push("admin");
    if (grants.holdsOperationalGuardian) holdsGuardians.push("operational");
    out.push({
      name,
      grantPolicy: grants.grantPolicy,
      holdsGuardians,
      addressByEnv: ENVS.reduce(
        (acc, env) => {
          acc[env] = dumps[env].profiles[name] ?? "";
          return acc;
        },
        {} as Record<Env, string>,
      ),
    });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

function assertProfileSetMatches(profiles: Map<string, ProfileGrants>, dump: ForgeDump): void {
  const parsedSet = new Set(profiles.keys());
  const dumpSet = new Set(Object.keys(dump.profiles));
  for (const name of parsedSet) {
    if (!dumpSet.has(name)) {
      throw new Error(`Profile "${name}" parsed from setup files but missing from Forge dump`);
    }
  }
  for (const name of dumpSet) {
    if (!parsedSet.has(name)) {
      throw new Error(`Profile "${name}" present in Forge dump but not in setup files`);
    }
  }
}

function invertProfileGrants(
  profiles: ReturnType<typeof parseProfiles>,
  order: string[],
): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const fn of order) out.set(fn, []);

  const allFns = order;
  const sortedProfiles = [...profiles.values()].sort((a, b) => a.profile.localeCompare(b.profile));

  for (const profile of sortedProfiles) {
    let granted: string[] = [];
    if (profile.grantPolicy === "ALL") {
      granted = allFns;
    } else if (profile.grantPolicy === "ALL_NON_CRITICAL") {
      // Filled in by caller, but we need criticalRisk per fn — defer to a wrapper.
      granted = []; // Sentinel: pushed back by the caller with full info.
    } else {
      granted = profile.explicitGetRoleFns;
    }
    for (const fn of granted) {
      const list = out.get(fn);
      if (!list) {
        throw new Error(`Profile ${profile.profile} references unknown getRole fn: ${fn}`);
      }
      list.push(profile.profile);
    }
  }

  return out;
}

interface BuildRolesArgs {
  order: string[];
  natspec: ReturnType<typeof parseRolesConfig>;
  dumps: Record<Env, ForgeDump>;
  grantsByGetRoleFn: Map<string, string[]>;
  signatures: ReturnType<typeof loadSignatureLookup>;
}

function buildRoles(args: BuildRolesArgs): RoleJson[] {
  const { order, natspec, dumps, grantsByGetRoleFn, signatures } = args;
  const referenceDump = dumps.staging;

  // Resolve ALL_NON_CRITICAL grants now that we have the criticalRisk-per-index data.
  applyNonCriticalGrants(grantsByGetRoleFn, order, referenceDump);

  const out: RoleJson[] = [];
  for (let i = 0; i < order.length; i++) {
    const fn = order[i]!;
    const meta = natspec.get(fn);
    if (!meta) throw new Error(`No natspec for ${fn}`);
    const dumpRow = referenceDump.roles[i]!;

    const signature = lookupSignature(signatures, meta.selectorSourceContract, dumpRow.selector);
    const guardian: GuardianName = guardianFor(dumpRow.guardianRoleId, referenceDump);
    const grantedTo = (grantsByGetRoleFn.get(fn) ?? []).slice().sort((a, b) => a.localeCompare(b));

    out.push({
      key: `${meta.contract}.${meta.selectorSourceFunction}`,
      selector: dumpRow.selector,
      signature: `${meta.selectorSourceFunction}${signature.slice(signature.indexOf("("))}`,
      contract: meta.contract,
      locations: meta.locations,
      delayTier: meta.delayTier,
      guardian,
      criticalRisk: dumpRow.criticalRisk,
      grantedTo,
      delaySeconds: ENVS.reduce(
        (acc, env) => {
          acc[env] = dumps[env].roles[i]!.delaySeconds;
          return acc;
        },
        {} as Record<Env, number>,
      ),
      roleId: dumpRow.roleId,
      getRoleFn: fn,
      status: "Active",
    });
  }
  return out;
}

function applyNonCriticalGrants(
  grantsByGetRoleFn: Map<string, string[]>,
  order: string[],
  dump: ForgeDump,
): void {
  const nonCriticalProfiles = ["SecondaryAdmin"];
  for (let i = 0; i < order.length; i++) {
    const fn = order[i]!;
    const role = dump.roles[i]!;
    if (role.criticalRisk) continue;
    const list = grantsByGetRoleFn.get(fn);
    if (!list) continue;
    for (const profile of nonCriticalProfiles) {
      if (!list.includes(profile)) list.push(profile);
    }
  }
}

function guardianFor(guardianRoleId: number, dump: ForgeDump): GuardianName {
  if (guardianRoleId === dump.adminGuardianRoleId) return "admin";
  if (guardianRoleId === dump.operationalGuardianRoleId) return "operational";
  throw new Error(`Unknown guardian role id ${guardianRoleId}`);
}

function sha256OfFile(path: string): string {
  if (!path) return "";
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

main();
