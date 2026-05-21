/**
 * Validates `script/output/roles.json` against the invariants that the rest of the pipeline relies on. Fails non-zero
 * on any violation so it can be wired into CI as a blocking check. Designed to catch the kinds of slow drift that
 * audit reviewers would otherwise have to chase manually: selector collisions, key collisions, delay tier inversions,
 * orphaned profile grants.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { DELAY_TIER_NAMES, ENVS, type Env, type RolesArtifact } from "./lib/types.js";

const ROLES_JSON_PATH = join(process.cwd(), "script/output/roles.json");

function main(): void {
  const artifact = JSON.parse(readFileSync(ROLES_JSON_PATH, "utf8")) as RolesArtifact;
  const failures: string[] = [];

  const fail = (msg: string): void => {
    failures.push(msg);
  };

  const activeRoles = artifact.roles.filter((r) => r.status === "Active");

  assertUniqueBy(activeRoles, (r) => r.selector, "selector", fail);
  assertUniqueBy(activeRoles, (r) => r.key, "key", fail);
  assertUniqueBy(activeRoles, (r) => r.roleId, "roleId", fail);

  const tierByName = new Map(artifact.delayTiers.map((t) => [t.name, t]));
  for (const tier of artifact.delayTiers) {
    if (!DELAY_TIER_NAMES.includes(tier.name)) {
      fail(`Unknown delay tier "${tier.name}" in artifact`);
    }
  }
  if (artifact.delayTiers.length !== DELAY_TIER_NAMES.length) {
    fail(`Delay tier count ${artifact.delayTiers.length} != ${DELAY_TIER_NAMES.length}`);
  }
  for (const env of ENVS) {
    const noDelay = tierByName.get("NO_DELAY")?.secondsByEnv[env];
    if (noDelay !== 0) fail(`NO_DELAY (${env}) must equal 0, got ${noDelay}`);
    const ordering: { name: string; seconds: number | undefined }[] = [
      { name: "LOW", seconds: tierByName.get("LOW")?.secondsByEnv[env] },
      { name: "MEDIUM", seconds: tierByName.get("MEDIUM")?.secondsByEnv[env] },
      { name: "HIGH", seconds: tierByName.get("HIGH")?.secondsByEnv[env] },
      { name: "CRITICAL", seconds: tierByName.get("CRITICAL")?.secondsByEnv[env] },
    ];
    for (let i = 1; i < ordering.length; i++) {
      const prev = ordering[i - 1]!;
      const cur = ordering[i]!;
      if (typeof prev.seconds !== "number" || typeof cur.seconds !== "number") continue;
      if (prev.seconds > cur.seconds) {
        fail(`Delay ordering violated in ${env}: ${prev.name} (${prev.seconds}s) > ${cur.name} (${cur.seconds}s)`);
      }
    }
  }

  const profileNames = new Set(artifact.profiles.map((p) => p.name));
  for (const role of activeRoles) {
    if (!tierByName.has(role.delayTier)) {
      fail(`Role ${role.key}: unknown delayTier "${role.delayTier}"`);
      continue;
    }
    const tier = tierByName.get(role.delayTier)!;
    for (const env of ENVS) {
      if (role.delaySeconds[env] !== tier.secondsByEnv[env]) {
        fail(
          `Role ${role.key} (${env}): delaySeconds ${role.delaySeconds[env]} != ${role.delayTier} tier ${tier.secondsByEnv[env]}`,
        );
      }
    }
    for (const profile of role.grantedTo) {
      if (!profileNames.has(profile)) {
        fail(`Role ${role.key}: grantedTo references unknown profile "${profile}"`);
      }
    }
  }

  const mainAdmin = artifact.profiles.find((p) => p.name === "MainAdmin");
  if (mainAdmin?.grantPolicy !== "ALL") {
    fail(`MainAdmin must have grantPolicy=ALL (got ${mainAdmin?.grantPolicy})`);
  } else {
    for (const role of activeRoles) {
      if (!role.grantedTo.includes("MainAdmin")) {
        fail(`Role ${role.key}: ALL-policy MainAdmin missing from grantedTo`);
      }
    }
  }

  const secondaryAdmin = artifact.profiles.find((p) => p.name === "SecondaryAdmin");
  if (secondaryAdmin?.grantPolicy !== "ALL_NON_CRITICAL") {
    fail(`SecondaryAdmin must have grantPolicy=ALL_NON_CRITICAL (got ${secondaryAdmin?.grantPolicy})`);
  } else {
    for (const role of activeRoles) {
      const hasSec = role.grantedTo.includes("SecondaryAdmin");
      if (role.criticalRisk && hasSec) {
        fail(`Role ${role.key}: critical-risk role granted to SecondaryAdmin (ALL_NON_CRITICAL policy violated)`);
      }
      if (!role.criticalRisk && !hasSec) {
        fail(`Role ${role.key}: non-critical role missing SecondaryAdmin grant (ALL_NON_CRITICAL policy violated)`);
      }
    }
  }

  if (failures.length === 0) {
    console.log(
      `OK: ${activeRoles.length} active roles, ${artifact.profiles.length} profiles, ${artifact.delayTiers.length} delay tiers — all invariants hold.`,
    );
    return;
  }

  console.error(`FAIL: ${failures.length} invariant violations:`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

function assertUniqueBy<T, K>(rows: T[], keyFn: (r: T) => K, label: string, fail: (msg: string) => void): void {
  const seen = new Map<K, T>();
  for (const row of rows) {
    const k = keyFn(row);
    const prev = seen.get(k);
    if (prev) {
      fail(`Duplicate ${label} "${String(k)}" across two active rows`);
      continue;
    }
    seen.set(k, row);
  }
}

main();
