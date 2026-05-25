// Render CheckResult[] for stdout. Four modes:
//   - full:    one row per check with key | expected | on-chain | status (default)
//   - summary: one line per group with `X / Y ✓`
//   - quiet:   failures only (no pass rows)
//   - json:    machine-readable; bypasses the renderer entirely (handled in run.ts)

import Table from "cli-table3";
import pc from "picocolors";

import { humanise, statusGlyph } from "./format.js";
import type { CheckResult, RenderMode, SmokeReport } from "./types.js";

export function renderBanner(report: SmokeReport): string {
  const m = report.meta;
  const title = ` stable-vault smoke • ${m.env} • ${m.chain} • chainId ${m.chainId} `;
  const top = `╔${"═".repeat(title.length)}╗`;
  const bottom = `╚${"═".repeat(title.length)}╝`;
  return [
    top,
    `║${pc.bold(title)}║`,
    bottom,
    `commit ${m.commit.slice(0, 8)} · rpc ${m.rpcUrlMasked} · block ${m.blockNumber}`,
    "",
  ].join("\n");
}

export function render(report: SmokeReport, mode: RenderMode): string {
  switch (mode) {
    case "summary":
      return renderSummary(report);
    case "quiet":
      return renderQuiet(report);
    case "full":
      return renderFull(report);
    case "json":
      // run.ts handles JSON directly to bypass stdout colour codes.
      return JSON.stringify(report, replaceBigInt, 2);
  }
}

function renderFull(report: SmokeReport): string {
  const out: string[] = [renderBanner(report)];
  const groups = groupBy(report.results, (r) => r.group);
  for (const [groupName, checks] of groups) {
    const passed = checks.filter((c) => c.severity === "pass").length;
    out.push(pc.bold(`▸ ${groupName}  ${passed}/${checks.length}`));
    const table = new Table({
      head: ["", "key", "expected", "on-chain", "note"],
      style: { head: ["dim"], border: ["dim"] },
      colAligns: ["center", "left", "right", "right", "left"],
      wordWrap: true,
    });
    for (const c of checks) {
      const glyph = colourGlyph(c.severity);
      table.push([
        glyph,
        c.key,
        humanise(c.expected, c.format, c.key),
        humanise(c.actual, c.format, c.key),
        c.note ? (c.severity === "fail" ? pc.red(c.note) : pc.dim(c.note)) : "",
      ]);
    }
    out.push(table.toString());
    out.push("");
  }
  out.push(renderTotals(report));
  return out.join("\n");
}

function renderSummary(report: SmokeReport): string {
  const out: string[] = [renderBanner(report)];
  const groups = groupBy(report.results, (r) => r.group);
  for (const [groupName, checks] of groups) {
    const passed = checks.filter((c) => c.severity === "pass").length;
    const failed = checks.filter((c) => c.severity === "fail" || c.severity === "error").length;
    const glyph = failed === 0 ? pc.green("✓") : pc.red("✗");
    out.push(`▸ ${groupName.padEnd(40)} ${passed}/${checks.length}  ${glyph}`);
  }
  out.push("");
  out.push(renderTotals(report));
  return out.join("\n");
}

function renderQuiet(report: SmokeReport): string {
  const failing = report.results.filter((r) => r.severity === "fail" || r.severity === "error");
  if (failing.length === 0) return `All ${report.summary.total} checks passed.`;
  const out: string[] = [];
  for (const c of failing) {
    out.push(
      `${colourGlyph(c.severity)} ${pc.bold(c.key)}\n    expected ${humanise(c.expected, c.format, c.key)}\n    actual   ${humanise(c.actual, c.format, c.key)}${c.note ? `\n    note     ${pc.red(c.note)}` : ""}`,
    );
  }
  out.push("");
  out.push(renderTotals(report));
  return out.join("\n");
}

function renderTotals(report: SmokeReport): string {
  const s = report.summary;
  const parts: string[] = [];
  parts.push(`${s.total} checks`);
  parts.push(s.pass > 0 ? pc.green(`${s.pass} pass`) : `${s.pass} pass`);
  if (s.fail > 0) parts.push(pc.red(`${s.fail} fail`));
  if (s.error > 0) parts.push(pc.red(`${s.error} error`));
  if (s.warning > 0) parts.push(pc.yellow(`${s.warning} warning`));
  if (s.skipped > 0) parts.push(pc.dim(`${s.skipped} skipped`));
  parts.push(pc.dim(`${(s.durationMs / 1000).toFixed(1)}s`));
  return parts.join(" · ");
}

function colourGlyph(severity: string): string {
  const g = statusGlyph(severity);
  switch (severity) {
    case "pass":
      return pc.green(g);
    case "fail":
    case "error":
      return pc.red(g);
    case "warning":
      return pc.yellow(g);
    case "skipped":
      return pc.dim(g);
    default:
      return g;
  }
}

function groupBy<T>(items: T[], key: (t: T) => string): Map<string, T[]> {
  const map = new Map<string, T[]>();
  for (const item of items) {
    const k = key(item);
    const list = map.get(k) ?? [];
    list.push(item);
    map.set(k, list);
  }
  return map;
}

// JSON.stringify replacer that emits bigint as numeric strings.
function replaceBigInt(_key: string, value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  return value;
}
