export type Env = "staging" | "preprod" | "prod";

export const ENVS: Env[] = ["staging", "preprod", "prod"];

export type DelayTierName = "NO_DELAY" | "LOW" | "MEDIUM" | "HIGH" | "CRITICAL";

export const DELAY_TIER_NAMES: DelayTierName[] = ["NO_DELAY", "LOW", "MEDIUM", "HIGH", "CRITICAL"];

export type GuardianName = "admin" | "operational";

export type GrantPolicy = "ALL" | "ALL_NON_CRITICAL" | "EXPLICIT";

export interface ForgeDumpRole {
  index: number;
  /** uint64; held as string because precision can exceed 2^53. */
  roleId: string;
  selector: string;
  delaySeconds: number;
  guardianRoleId: number;
  criticalRisk: boolean;
}

export interface ForgeDump {
  env: Env;
  deployer: string;
  lowDelaySeconds: number;
  mediumDelaySeconds: number;
  highDelaySeconds: number;
  criticalDelaySeconds: number;
  adminGuardianRoleId: number;
  operationalGuardianRoleId: number;
  profiles: Record<string, string>;
  roles: ForgeDumpRole[];
}

export interface NatspecRole {
  /** The `getRole__X` function name as declared in `RolesConfig.sol`. */
  getRoleFn: string;
  /** `@custom:delay` tag value, capitalised to match `DelayTierName` (None → NO_DELAY, Low → LOW, etc.). */
  delayTier: DelayTierName;
  /** Comma-separated string from `@custom:location`, possibly wrapped across natspec lines. */
  locationsRaw: string;
  /** Parsed list of target contracts from `locationsRaw`. */
  locations: string[];
  /** Interface or contract name from `X.fooBar.selector` (e.g. `IAssetRegistry`). */
  selectorSourceContract: string;
  /** Function name from `X.fooBar.selector` (e.g. `setAssetConfig`). */
  selectorSourceFunction: string;
  /** Normalised contract name used as the Notion `Contract` value — leading `I` stripped if interface-like. */
  contract: string;
}

export interface ProfileGrants {
  /** Profile identifier as it appears after `_setupProfile__` (e.g. `MainAdmin`). */
  profile: string;
  /** Whether grants are computed from the full role set, the non-critical subset, or an explicit list. */
  grantPolicy: GrantPolicy;
  /** For `EXPLICIT` profiles: ordered list of `getRole__X` function names that this profile is granted. */
  explicitGetRoleFns: string[];
  /** Whether this profile holds the admin guardian meta-role. */
  holdsAdminGuardian: boolean;
  /** Whether this profile holds the operational guardian meta-role. */
  holdsOperationalGuardian: boolean;
}

export interface DeploymentConfigSnapshot {
  env: Env;
  deployer: string;
  rebalancerMulticallOwner: string;
  disablerMulticallOwner: string;
  profiles: Record<string, string>;
}

export interface RoleJson {
  key: string;
  selector: string;
  signature: string;
  contract: string;
  locations: string[];
  delayTier: DelayTierName;
  guardian: GuardianName;
  criticalRisk: boolean;
  grantedTo: string[];
  delaySeconds: Record<Env, number>;
  roleId: string;
  getRoleFn: string;
  status: "Active";
}

export interface DelayTierJson {
  name: DelayTierName;
  secondsByEnv: Record<Env, number>;
}

export interface ProfileJson {
  name: string;
  grantPolicy: GrantPolicy;
  holdsGuardians: GuardianName[];
  addressByEnv: Record<Env, string>;
}

export interface RolesArtifact {
  generatedAt: string;
  source: {
    rolesConfigSha: string;
    accessManagerBaseSetupSha: string;
    accessManagerAccountingChainSetupSha: string;
    accessManagerEarningChainSetupSha: string;
  };
  delayTiers: DelayTierJson[];
  profiles: ProfileJson[];
  roles: RoleJson[];
}
