// Build the structured smoke report from CheckResult[] + RunMeta and write a
// dated JSON to tools/smoke/output/. The JSON is the audit-trail artefact that
// the operator attaches to a deploy PR.

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import type { CheckResult, RunMeta, SmokeReport } from "./types.js";

export function buildReport(meta: RunMeta, results: CheckResult[], durationMs: number): SmokeReport {
  const summary = {
    total: results.length,
    pass: results.filter((r) => r.severity === "pass").length,
    fail: results.filter((r) => r.severity === "fail").length,
    warning: results.filter((r) => r.severity === "warning").length,
    skipped: results.filter((r) => r.severity === "skipped").length,
    error: results.filter((r) => r.severity === "error").length,
    durationMs,
  };
  return { meta, results, summary };
}

export function writeReport(report: SmokeReport, repoRoot: string): string {
  const ts = report.meta.startedAt.replace(/[:.]/g, "-");
  const filename = `${report.meta.env}-${report.meta.chain}-${report.meta.network}-${ts}.json`;
  const outDir = join(repoRoot, "tools/smoke/output");
  const path = join(outDir, filename);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(report, replaceBigInt, 2));
  return path;
}

function replaceBigInt(_key: string, value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  return value;
}
