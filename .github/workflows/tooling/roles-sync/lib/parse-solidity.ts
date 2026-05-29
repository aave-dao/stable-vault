import { readFileSync } from "node:fs";

import type { DelayTierName, NatspecRole, ProfileGrants } from "./types.js";

const DELAY_TAG_MAP: Record<string, DelayTierName> = {
  none: "NO_DELAY",
  low: "LOW",
  medium: "MEDIUM",
  high: "HIGH",
  critical: "CRITICAL",
};

/**
 * Parses every `getRole__X` declaration in `RolesConfig.sol`. The natspec block immediately preceding each function is
 * scanned for `@custom:delay` and `@custom:location` tags, and the first line of the body is scanned for the
 * `bytes4 selector = Iface.fn.selector;` expression. Multi-line `@custom:location` values are supported.
 */
export function parseRolesConfig(path: string): Map<string, NatspecRole> {
  const lines = readFileSync(path, "utf8").split(/\r?\n/);

  const out = new Map<string, NatspecRole>();

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    const fnMatch = line.match(/^\s*function\s+(getRole__[A-Za-z0-9_]+)\s*\(/);
    if (!fnMatch) continue;
    const fnName = fnMatch[1] ?? "";

    const natspec = collectNatspecBefore(lines, i);
    const tags = parseNatspecTags(natspec);
    const selectorSource = findSelectorSource(lines, i);

    const delayRaw = (tags["delay"] ?? "").trim().toLowerCase();
    const delayTier = DELAY_TAG_MAP[delayRaw];
    if (!delayTier) {
      throw new Error(`${path}:${i + 1}: ${fnName}: missing/unknown @custom:delay tag (got "${tags["delay"] ?? ""}")`);
    }

    const locationsRaw = (tags["location"] ?? "").trim();
    if (!locationsRaw) {
      throw new Error(`${path}:${i + 1}: ${fnName}: missing @custom:location tag`);
    }
    const locations = locationsRaw
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
      .map(normaliseLocation);

    if (!selectorSource) {
      throw new Error(`${path}:${i + 1}: ${fnName}: missing "bytes4 selector = X.fn.selector;" inside body`);
    }

    out.set(fnName, {
      getRoleFn: fnName,
      delayTier,
      locationsRaw,
      locations,
      selectorSourceContract: selectorSource.contract,
      selectorSourceFunction: selectorSource.fn,
      contract: stripInterfacePrefix(selectorSource.contract),
    });
  }

  return out;
}

/** Returns the `getRole__X` function names called inside `getAllFunctionBasedRoles()`, in array-index order. */
export function parseGetAllFunctionBasedRolesOrder(path: string): string[] {
  const src = readFileSync(path, "utf8");
  const fnMatch = src.match(/function\s+getAllFunctionBasedRoles\s*\(\s*\)[^{]*\{([\s\S]*?)\n\s*\}/);
  if (!fnMatch) {
    throw new Error(`${path}: cannot find getAllFunctionBasedRoles() body`);
  }
  const body = fnMatch[1] ?? "";

  const ordered: { idx: number; fn: string }[] = [];
  const assignRe = /roles\[(\d+)\]\s*=\s*(getRole__[A-Za-z0-9_]+)\s*\(\s*\)/g;
  let m: RegExpExecArray | null;
  while ((m = assignRe.exec(body)) !== null) {
    ordered.push({ idx: Number(m[1]), fn: m[2] ?? "" });
  }
  ordered.sort((a, b) => a.idx - b.idx);
  ordered.forEach((entry, i) => {
    if (entry.idx !== i) {
      throw new Error(`getAllFunctionBasedRoles: expected index ${i}, got ${entry.idx} (${entry.fn})`);
    }
  });
  return ordered.map((e) => e.fn);
}

/**
 * Parses every `_setupProfile__X` function across the supplied AccessManager*Setup files and returns a flat map of
 * profile name → grants. `MainAdmin` is recognised as `ALL`; `SecondaryAdmin` as `ALL_NON_CRITICAL`; the rest are
 * captured as `EXPLICIT` with the ordered list of `RolesConfig.getRole__X()` calls. The function also picks up the
 * guardian-role grants (`ADMIN_ROLE_GUARDIAN_ROLE`, `OPERATIONAL_ROLE_GUARDIAN_ROLE`) per profile.
 */
export function parseProfiles(paths: string[]): Map<string, ProfileGrants> {
  const out = new Map<string, ProfileGrants>();

  for (const path of paths) {
    const src = readFileSync(path, "utf8");
    const headerRe = /function\s+_setupProfile__([A-Za-z0-9_]+)\s*\(\s*\)[^{]*\{/g;
    let m: RegExpExecArray | null;
    while ((m = headerRe.exec(src)) !== null) {
      const profile = m[1] ?? "";
      const bodyStart = headerRe.lastIndex;
      const bodyEnd = findMatchingBrace(src, bodyStart - 1);
      if (bodyEnd === -1) {
        throw new Error(`${path}: unbalanced braces in _setupProfile__${profile}`);
      }
      const body = src.slice(bodyStart, bodyEnd);

      const explicit: string[] = [];
      const callRe = /RolesConfig\.(getRole__[A-Za-z0-9_]+)\s*\(\s*\)/g;
      let c: RegExpExecArray | null;
      while ((c = callRe.exec(body)) !== null) {
        explicit.push(c[1] ?? "");
      }

      const grantPolicy = inferGrantPolicy(profile, body);

      out.set(profile, {
        profile,
        grantPolicy,
        explicitGetRoleFns: grantPolicy === "EXPLICIT" ? explicit : [],
        holdsAdminGuardian: hasGuardianGrant(body, "ADMIN_ROLE_GUARDIAN_ROLE"),
        holdsOperationalGuardian: hasGuardianGrant(body, "OPERATIONAL_ROLE_GUARDIAN_ROLE"),
      });
    }
  }

  return out;
}

/** True when the body grants the guardian meta-role to the profile (i.e. it appears as the FIRST arg of `grantRole`). */
function hasGuardianGrant(body: string, guardianName: string): boolean {
  const re = new RegExp(`grantRole\\s*,\\s*\\(\\s*RolesConfig\\.${guardianName}\\b`);
  return re.test(body);
}

/** Returns the index of the `}` that closes the `{` at `openIdx`, ignoring braces inside strings. -1 if unbalanced. */
function findMatchingBrace(src: string, openIdx: number): number {
  if (src[openIdx] !== "{") return -1;
  let depth = 0;
  let inString: '"' | "'" | null = null;
  let escape = false;
  for (let i = openIdx; i < src.length; i++) {
    const ch = src[i] ?? "";
    if (inString) {
      if (escape) escape = false;
      else if (ch === "\\") escape = true;
      else if (ch === inString) inString = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      inString = ch;
      continue;
    }
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function inferGrantPolicy(profile: string, body: string): ProfileGrants["grantPolicy"] {
  if (profile === "MainAdmin") return "ALL";
  if (profile === "SecondaryAdmin") return "ALL_NON_CRITICAL";
  if (/getAllFunctionBasedRoles\s*\(\s*\)/.test(body)) {
    throw new Error(
      `_setupProfile__${profile}: references getAllFunctionBasedRoles() but is not MainAdmin/SecondaryAdmin — add a case in inferGrantPolicy`,
    );
  }
  return "EXPLICIT";
}

function collectNatspecBefore(lines: string[], fnLineIdx: number): string[] {
  const collected: string[] = [];
  for (let j = fnLineIdx - 1; j >= 0; j--) {
    const trimmed = (lines[j] ?? "").trimStart();
    if (trimmed.startsWith("///")) {
      collected.unshift(trimmed.slice(3).trimStart());
      continue;
    }
    if (trimmed === "") continue;
    break;
  }
  return collected;
}

function parseNatspecTags(lines: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  let currentTag: string | null = null;
  for (const raw of lines) {
    const tagMatch = raw.match(/^@custom:([A-Za-z]+)\s*(.*)$/);
    if (tagMatch) {
      currentTag = (tagMatch[1] ?? "").toLowerCase();
      out[currentTag] = (tagMatch[2] ?? "").trim();
      continue;
    }
    if (currentTag && raw.trim().length > 0) {
      out[currentTag] = (out[currentTag] ?? "") + " " + raw.trim();
    }
  }
  return out;
}

function findSelectorSource(lines: string[], fnLineIdx: number): { contract: string; fn: string } | null {
  for (let j = fnLineIdx + 1; j < Math.min(fnLineIdx + 10, lines.length); j++) {
    const line = lines[j] ?? "";
    const m = line.match(/bytes4\s+selector\s*=\s*([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\.selector\s*;/);
    if (m) return { contract: m[1] ?? "", fn: m[2] ?? "" };
  }
  return null;
}

function stripInterfacePrefix(name: string): string {
  if (name.length >= 2 && name.startsWith("I") && name.charCodeAt(1) >= 0x41 && name.charCodeAt(1) <= 0x5a) {
    return name.slice(1);
  }
  return name;
}

function normaliseLocation(loc: string): string {
  if (loc === "aToken Vault") return "ATokenVault";
  return loc;
}
