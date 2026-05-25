// AccessManager parity entries driven by script/output/roles.json.
//
// For every role:
//   1. getRoleGrantDelay(roleId) → expected delaySeconds[env]
//   2. For each profile in grantedTo[]: hasRole(roleId, profileAddress) → (true, 0)
//   3. getTargetFunctionRole(<contract.address>, <selector>) → roleId
//
// Plus two structural assertions:
//   - hasRole(ADMIN_ROLE=0, deployer) → false  (deployer must have been revoked)
//   - hasRole(ADMIN_ROLE=0, mainAdmin)  → true   (main admin must hold ADMIN_ROLE)

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { getAddress, type Address, type Hex } from "viem";

import { tryEntry } from "../artefact.js";
import { ACCESS_MANAGER_ABI } from "./abis.js";
import type { GetterSpec } from "../parity.js";
import type { ChainKind, DeploymentArtefact, Env } from "../types.js";

const ADMIN_ROLE_ID = 0n;

interface RolesJson {
  delayTiers: { name: string; secondsByEnv: Record<Env, number> }[];
  profiles: { name: string; addressByEnv: Record<Env, string> }[];
  roles: {
    key: string;
    selector: Hex;
    contract: string;
    locations: string[];
    delayTier: string;
    grantedTo: string[];
    delaySeconds: Record<Env, number>;
    roleId: string;
    status: string;
  }[];
}

export interface AccessArgs {
  env: Env;
  chain: ChainKind;
  artefact: DeploymentArtefact;
  deployer: Address;
  repoRoot: string;
  config: Record<string, unknown>;
}

export function buildAccessSpecs(args: AccessArgs): GetterSpec[] {
  const { env, chain, artefact, deployer, repoRoot, config } = args;
  const accessManager = tryEntry(artefact, "AccessManager");
  if (!accessManager) return [];

  const rolesPath = resolve(repoRoot, "script/output/roles.json");
  const roles = JSON.parse(readFileSync(rolesPath, "utf8")) as RolesJson;
  const profiles = new Map(roles.profiles.map((p) => [p.name, p.addressByEnv[env]]));
  const specs: GetterSpec[] = [];

  // Filter roles to those relevant for the chain we're on. roles.json carries
  // every role across both chains; AC-only and EC-only roles are distinguished
  // by the `locations[]` array (contract names). A role is relevant if the
  // chain's artefact contains at least one of its location contracts.
  const isRoleRelevant = (locations: string[]): boolean =>
    locations.some((loc) => artefact.entries.has(loc));

  for (const role of roles.roles) {
    if (role.status !== "Active") continue;
    if (!isRoleRelevant(role.locations)) continue;

    const roleId = BigInt(role.roleId);
    const expectedDelay = BigInt(role.delaySeconds[env]);

    // 1. Delay parity
    specs.push({
      group: "AccessManager",
      key: `AccessManager.${role.key}.delay`,
      address: accessManager.address,
      abi: ACCESS_MANAGER_ABI,
      functionName: "getRoleGrantDelay",
      args: [roleId],
      expected: expectedDelay,
      format: "seconds",
    });

    // 2. Profile-grant parity
    for (const profileName of role.grantedTo) {
      const profileAddrStr = profiles.get(profileName);
      if (!profileAddrStr || profileAddrStr === "0x0000000000000000000000000000000000000000") {
        // Profile is a TBD placeholder — flag as skipped so it surfaces in output.
        specs.push({
          group: "AccessManager",
          key: `AccessManager.${role.key}.grants.${profileName}`,
          address: accessManager.address,
          abi: ACCESS_MANAGER_ABI,
          functionName: "hasRole",
          args: [roleId, "0x0000000000000000000000000000000000000000"],
          expected: true,
          format: "bool",
          skipIf: { reason: `profile ${profileName} address is zero (TBD) in ${env} config` },
        });
        continue;
      }
      const profileAddr = getAddress(profileAddrStr);
      specs.push({
        group: "AccessManager",
        key: `AccessManager.${role.key}.grants.${profileName}`,
        address: accessManager.address,
        abi: ACCESS_MANAGER_ABI,
        functionName: "hasRole",
        args: [roleId, profileAddr],
        expected: true,
        format: "bool",
        pick: (raw) => (raw as readonly [boolean, number])[0],
      });
    }

    // 3. Target-function-role parity: confirm the contract.selector mapping points at roleId.
    const targetEntry = tryEntry(artefact, role.contract);
    if (targetEntry) {
      specs.push({
        group: "AccessManager",
        key: `AccessManager.${role.key}.target`,
        address: accessManager.address,
        abi: ACCESS_MANAGER_ABI,
        functionName: "getTargetFunctionRole",
        args: [targetEntry.address, role.selector],
        expected: roleId,
        format: "uint",
      });
    }
  }

  // Structural assertion 1: deployer's ADMIN_ROLE must be revoked.
  specs.push({
    group: "AccessManager",
    key: `AccessManager.deployer.ADMIN_ROLE.revoked`,
    address: accessManager.address,
    abi: ACCESS_MANAGER_ABI,
    functionName: "hasRole",
    args: [ADMIN_ROLE_ID, deployer],
    expected: false,
    format: "bool",
    pick: (raw) => (raw as readonly [boolean, number])[0],
  });

  // Structural assertion 2: main admin holds ADMIN_ROLE.
  const mainAdminProfile = profiles.get("MainAdmin");
  if (mainAdminProfile && mainAdminProfile !== "0x0000000000000000000000000000000000000000") {
    specs.push({
      group: "AccessManager",
      key: `AccessManager.mainAdmin.ADMIN_ROLE.held`,
      address: accessManager.address,
      abi: ACCESS_MANAGER_ABI,
      functionName: "hasRole",
      args: [ADMIN_ROLE_ID, getAddress(mainAdminProfile)],
      expected: true,
      format: "bool",
      pick: (raw) => (raw as readonly [boolean, number])[0],
    });
  }

  // Reference unused params to keep typecheck quiet (chain/config kept on the
  // interface because future cross-chain delays may want them).
  void chain;
  void config;

  return specs;
}
