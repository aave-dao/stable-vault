// Supply-chain defense: verify every dep added by the smoke harness was
// published to the npm registry at least MIN_AGE_DAYS ago. Catches the
// "freshly compromised package" attack class (where a malicious version is
// briefly published, installed by automation, then yanked).
//
// Run via `yarn smoke:audit-deps`. Fails CI on violation.
//
// Scope: only deps owned by the smoke harness. The rest of the repo's deps
// are out of scope here — they're audited via dependabot + `yarn audit`.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const MIN_AGE_DAYS = 7;
const MIN_AGE_MS = MIN_AGE_DAYS * 24 * 60 * 60 * 1000;

// Direct deps the smoke harness introduced. Add a new entry when smoke gains a
// new direct dep; transitive deps are intentionally excluded (auditing them is
// the job of dependabot + the lockfile, not this gate).
const SMOKE_DIRECT_DEPS = ["viem", "picocolors", "cli-table3"] as const;

interface NpmTimeResponse {
  time: Record<string, string>;
}

async function main(): Promise<void> {
  const repoRoot = process.cwd();
  const pkg = JSON.parse(readFileSync(resolve(repoRoot, "package.json"), "utf8")) as {
    devDependencies: Record<string, string>;
    dependencies?: Record<string, string>;
  };
  const allDeps = { ...(pkg.dependencies ?? {}), ...pkg.devDependencies };
  const now = Date.now();
  const violations: string[] = [];

  for (const name of SMOKE_DIRECT_DEPS) {
    const range = allDeps[name];
    if (!range) {
      violations.push(`${name}: declared in SMOKE_DIRECT_DEPS but missing from package.json`);
      continue;
    }
    // Reject caret / tilde / wildcard ranges outright — they defeat the lockfile
    // guarantee that this script audits the actually-installed version.
    if (!/^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$/.test(range)) {
      violations.push(`${name}@${range}: must be pinned to an exact version (no ^, ~, or wildcards)`);
      continue;
    }
    const pinned = range;
    let publishedAt: string | undefined;
    try {
      const res = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}`, {
        headers: { Accept: "application/json" },
      });
      if (!res.ok) {
        violations.push(`${name}@${pinned}: registry returned ${res.status}`);
        continue;
      }
      const data = (await res.json()) as NpmTimeResponse;
      publishedAt = data.time[pinned];
    } catch (e) {
      violations.push(`${name}@${pinned}: registry fetch failed (${(e as Error).message})`);
      continue;
    }
    if (!publishedAt) {
      violations.push(`${name}@${pinned}: version not found in registry time map`);
      continue;
    }
    const ageMs = now - new Date(publishedAt).getTime();
    const ageDays = Math.floor(ageMs / (24 * 60 * 60 * 1000));
    if (ageMs < MIN_AGE_MS) {
      violations.push(
        `${name}@${pinned}: published ${publishedAt} (${ageDays}d old, < ${MIN_AGE_DAYS}d minimum)`,
      );
      continue;
    }
    process.stdout.write(`ok  ${name.padEnd(16)} ${pinned.padEnd(12)} ${publishedAt.slice(0, 10)}  (${ageDays}d)\n`);
  }

  if (violations.length > 0) {
    process.stderr.write(`\n${violations.length} violation(s):\n`);
    for (const v of violations) process.stderr.write(`  - ${v}\n`);
    process.stderr.write(
      `\nPolicy: smoke-harness deps must be pinned to exact versions and published ≥ ${MIN_AGE_DAYS} days ago.\n`,
    );
    process.exit(1);
  }
}

main().catch((err: Error) => {
  process.stderr.write(`fatal: ${err.message}\n`);
  process.exit(1);
});
