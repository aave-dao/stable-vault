/**
 * Mirrors `script/output/roles.json` into the three Notion databases under
 * `Stable-Vaults: Access Control`. Idempotent: the sync writes only managed properties, leaves human-edited columns
 * (`Notes`, `Risk Notes`) and page icons alone, and flips orphaned rows to `Status=Removed` rather than deleting them
 * so historical comments survive.
 *
 * Requires `NOTION_API_KEY` to be set. Database IDs default to the production IDs we created, but can be overridden
 * via env vars for testing.
 *
 * Matching keys:
 *   - Delay Tiers: `Name` (title) — the SoT enum is fixed (`NO_DELAY`, `LOW`, `MEDIUM`, `HIGH`, `CRITICAL`).
 *   - Profiles:    `Name` (title).
 *   - Roles:       `Selector` (rich_text) — stable across renames; `Key` may change.
 */
import { Client, isFullPage } from "@notionhq/client";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import {
  ENVS,
  type DelayTierJson,
  type Env,
  type GuardianName,
  type ProfileJson,
  type RoleJson,
  type RolesArtifact,
} from "./lib/types.js";

const ROLES_JSON_PATH = join(process.cwd(), "script/output/roles.json");

// Notion's REST API (version 2022-06-28, which @notionhq/client v4 still pins by default) addresses inline databases
// by the **page id** of the database block itself — *not* by the data-source / collection id. The DS id is a separate
// concept (the schema/collection backing the database) and the API will return 404 if you pass it.
const DELAY_TIERS_DB_ID = process.env.NOTION_DB_DELAY_TIERS ?? "d80957bc-1120-483f-8c2a-e579400b2fd7";
const PROFILES_DB_ID = process.env.NOTION_DB_PROFILES ?? "ccde62bc-c67a-4a0f-be99-c496a2cc0c5c";
const ROLES_DB_ID = process.env.NOTION_DB_ROLES ?? "23ceb4ce-dd69-429d-89b6-ff070554680c";

const DRY_RUN = process.env.NOTION_DRY_RUN === "1";

interface ExistingRow {
  pageId: string;
  matchKey: string;
  status: string | null;
}

async function main(): Promise<void> {
  const apiKey = process.env.NOTION_API_KEY;
  if (!apiKey) {
    console.error("NOTION_API_KEY is required");
    process.exit(1);
  }

  const notion = new Client({ auth: apiKey });
  const artifact = JSON.parse(readFileSync(ROLES_JSON_PATH, "utf8")) as RolesArtifact;

  const tierRowsByName = await fetchAllRows(notion, DELAY_TIERS_DB_ID, (page) => titleOf(page, "Name"));
  const profileRowsByName = await fetchAllRows(notion, PROFILES_DB_ID, (page) => titleOf(page, "Name"));
  const roleRowsBySelector = await fetchAllRows(notion, ROLES_DB_ID, (page) =>
    richTextOf(page, "Selector").toLowerCase(),
  );

  const tierPageIdByName = await syncDelayTiers(notion, artifact.delayTiers, tierRowsByName);
  const profilePageIdByName = await syncProfiles(notion, artifact.profiles, profileRowsByName);
  await syncRoles(notion, artifact.roles, roleRowsBySelector, tierPageIdByName, profilePageIdByName);

  await markOrphans(notion, "Delay Tier", tierRowsByName, new Set(artifact.delayTiers.map((t) => t.name)));
  await markOrphans(notion, "Profile", profileRowsByName, new Set(artifact.profiles.map((p) => p.name)));
  await markOrphans(
    notion,
    "Role",
    roleRowsBySelector,
    new Set(artifact.roles.map((r) => r.selector.toLowerCase())),
  );

  console.log(DRY_RUN ? "Dry-run complete (no writes performed)." : "Sync complete.");
}

async function syncDelayTiers(
  notion: Client,
  tiers: DelayTierJson[],
  existing: Map<string, ExistingRow>,
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  for (const tier of tiers) {
    const props: Record<string, unknown> = {
      Name: { title: [{ text: { content: tier.name } }] },
      ...envSecondsProps(tier.secondsByEnv),
      ...envHumanProps(tier.secondsByEnv),
      Status: { select: { name: "Active" } },
    };

    const found = existing.get(tier.name);
    if (found) {
      await update(notion, found.pageId, props, `delay tier ${tier.name}`);
      out.set(tier.name, found.pageId);
    } else {
      const pageId = await create(notion, DELAY_TIERS_DB_ID, props, `delay tier ${tier.name}`);
      out.set(tier.name, pageId);
    }
  }
  return out;
}

async function syncProfiles(
  notion: Client,
  profiles: ProfileJson[],
  existing: Map<string, ExistingRow>,
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  for (const profile of profiles) {
    const props: Record<string, unknown> = {
      Name: { title: [{ text: { content: profile.name } }] },
      "Grant Policy": { select: { name: profile.grantPolicy } },
      "Holds Guardian": { multi_select: profile.holdsGuardians.map((g) => ({ name: g })) },
      "Address (staging)": richTextProp(profile.addressByEnv.staging),
      "Address (preprod)": richTextProp(profile.addressByEnv.preprod),
      "Address (prod)": richTextProp(profile.addressByEnv.prod),
      Status: { select: { name: "Active" } },
    };

    const found = existing.get(profile.name);
    if (found) {
      await update(notion, found.pageId, props, `profile ${profile.name}`);
      out.set(profile.name, found.pageId);
    } else {
      const pageId = await create(notion, PROFILES_DB_ID, props, `profile ${profile.name}`);
      out.set(profile.name, pageId);
    }
  }
  return out;
}

async function syncRoles(
  notion: Client,
  roles: RoleJson[],
  existing: Map<string, ExistingRow>,
  tierPageIdByName: Map<string, string>,
  profilePageIdByName: Map<string, string>,
): Promise<void> {
  for (const role of roles) {
    const tierPageId = tierPageIdByName.get(role.delayTier);
    if (!tierPageId) throw new Error(`No Notion page id for delay tier ${role.delayTier}`);
    const grantedPageIds: string[] = [];
    for (const profile of role.grantedTo) {
      const id = profilePageIdByName.get(profile);
      if (!id) throw new Error(`No Notion page id for profile ${profile}`);
      grantedPageIds.push(id);
    }

    const props: Record<string, unknown> = {
      Key: { title: [{ text: { content: role.key } }] },
      Selector: richTextProp(role.selector),
      Signature: richTextProp(role.signature),
      Contract: { select: { name: role.contract } },
      Delay: { relation: [{ id: tierPageId }] },
      Guardian: { select: { name: guardianLabel(role.guardian) } },
      "Critical Risk": { checkbox: role.criticalRisk },
      "Granted To": { relation: grantedPageIds.map((id) => ({ id })) },
      Locations: richTextProp(role.locations.join(", ")),
      Status: { select: { name: "Active" } },
    };

    const found = existing.get(role.selector.toLowerCase());
    if (found) {
      await update(notion, found.pageId, props, `role ${role.key}`);
    } else {
      await create(notion, ROLES_DB_ID, props, `role ${role.key}`);
    }
  }
}

async function markOrphans(
  notion: Client,
  label: string,
  existing: Map<string, ExistingRow>,
  keptKeys: Set<string>,
): Promise<void> {
  for (const [key, row] of existing) {
    if (keptKeys.has(key)) continue;
    if (row.status === "Removed") continue;
    await update(notion, row.pageId, { Status: { select: { name: "Removed" } } }, `${label} orphan ${key}`);
  }
}

async function fetchAllRows(
  notion: Client,
  databaseId: string,
  keyFn: (page: PageObject) => string,
): Promise<Map<string, ExistingRow>> {
  const out = new Map<string, ExistingRow>();
  let cursor: string | undefined;
  while (true) {
    const res = await notion.databases.query({ database_id: databaseId, start_cursor: cursor, page_size: 100 });
    for (const result of res.results) {
      if (!isFullPage(result)) continue;
      const page = result as PageObject;
      const key = keyFn(page);
      if (!key) continue;
      out.set(key, { pageId: page.id, matchKey: key, status: selectOf(page, "Status") });
    }
    if (!res.has_more) break;
    cursor = res.next_cursor ?? undefined;
  }
  return out;
}

async function create(
  notion: Client,
  databaseId: string,
  properties: Record<string, unknown>,
  label: string,
): Promise<string> {
  if (DRY_RUN) {
    console.log(`[dry-run] CREATE ${label}`);
    return "dry-run-id";
  }
  const res = await notion.pages.create({
    parent: { database_id: databaseId },
    properties: properties as never,
  });
  console.log(`CREATE ${label}`);
  return res.id;
}

async function update(
  notion: Client,
  pageId: string,
  properties: Record<string, unknown>,
  label: string,
): Promise<void> {
  if (DRY_RUN) {
    console.log(`[dry-run] UPDATE ${label}`);
    return;
  }
  await notion.pages.update({ page_id: pageId, properties: properties as never });
  console.log(`UPDATE ${label}`);
}

function envSecondsProps(seconds: Record<Env, number>): Record<string, unknown> {
  return ENVS.reduce(
    (acc, env) => {
      acc[`Seconds (${env})`] = { number: seconds[env] };
      return acc;
    },
    {} as Record<string, unknown>,
  );
}

function envHumanProps(seconds: Record<Env, number>): Record<string, unknown> {
  return ENVS.reduce(
    (acc, env) => {
      acc[`Human (${env})`] = richTextProp(humanise(seconds[env]));
      return acc;
    },
    {} as Record<string, unknown>,
  );
}

function richTextProp(value: string): Record<string, unknown> {
  return { rich_text: value ? [{ text: { content: value } }] : [] };
}

function guardianLabel(g: GuardianName): string {
  return g;
}

function humanise(seconds: number): string {
  if (seconds === 0) return "—";
  if (seconds < 3600) return `${Math.round(seconds / 60)} min`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)} h`;
  return `${Math.round(seconds / 86400)} d`;
}

interface PageObject {
  id: string;
  properties: Record<string, unknown>;
}

function titleOf(page: PageObject, propName: string): string {
  const prop = page.properties[propName] as { title?: { plain_text?: string }[] } | undefined;
  return (prop?.title ?? []).map((t) => t.plain_text ?? "").join("");
}

function richTextOf(page: PageObject, propName: string): string {
  const prop = page.properties[propName] as { rich_text?: { plain_text?: string }[] } | undefined;
  return (prop?.rich_text ?? []).map((t) => t.plain_text ?? "").join("");
}

function selectOf(page: PageObject, propName: string): string | null {
  const prop = page.properties[propName] as { select?: { name?: string } | null } | undefined;
  return prop?.select?.name ?? null;
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
