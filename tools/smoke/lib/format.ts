// Humanise raw values for the operator view. RAY (1e27) values become "$X.XX",
// per-second rates become "$/day", asset-wei values get scaled to the asset's
// decimals + symbol, etc. Mirrors the algorithms in tools/roles/lib/parameters.ts.

import type { ValueFormat } from "./types.js";

const RAY = 10n ** 27n;
const BPS = 10_000n;
const SECONDS_PER_DAY = 86_400n;

const ASSET_META: Record<string, { decimals: number; symbol: string }> = {
  gho: { decimals: 18, symbol: "GHO" },
  usdc: { decimals: 6, symbol: "USDC" },
  usdt: { decimals: 6, symbol: "USDT" },
};

export function humanise(value: unknown, format?: ValueFormat, key?: string): string {
  if (value === undefined || value === null) return "—";
  if (format === undefined || format === "raw") return formatRaw(value);

  switch (format) {
    case "address":
      return typeof value === "string" ? abbreviateAddress(value) : String(value);
    case "bool":
      return value ? "true" : "false";
    case "bps":
      return formatBps(toBig(value));
    case "seconds":
      return formatSeconds(toBig(value));
    case "ray":
      return formatRay(toBig(value));
    case "rayPerSec":
      return formatRayPerSecond(toBig(value));
    case "assetWei":
      return formatAssetWei(toBig(value), key);
    case "assetWeiPerSec":
      return formatAssetWeiPerSecond(toBig(value), key);
    case "uint":
      return toBig(value).toLocaleString("en-US");
    case "bytes32":
      return typeof value === "string" ? `${value.slice(0, 10)}…${value.slice(-8)}` : String(value);
    default:
      return formatRaw(value);
  }
}

function formatRaw(v: unknown): string {
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (typeof v === "string") return v;
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

function toBig(v: unknown): bigint {
  if (typeof v === "bigint") return v;
  if (typeof v === "number") return BigInt(v);
  if (typeof v === "string") return BigInt(v);
  if (typeof v === "boolean") return v ? 1n : 0n;
  throw new Error(`cannot coerce ${typeof v} to bigint`);
}

function abbreviateAddress(addr: string): string {
  if (addr.length < 10) return addr;
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function formatBps(value: bigint): string {
  // 1 bps = 0.01%
  const whole = value / 100n;
  const frac = value % 100n;
  if (frac === 0n) return `${value} bps (${whole}%)`;
  return `${value} bps (${whole}.${frac.toString().padStart(2, "0")}%)`;
}

function formatSeconds(value: bigint): string {
  const v = Number(value);
  if (v < 60) return `${v}s`;
  if (v < 3600) return `${v}s (${(v / 60).toFixed(0)}m)`;
  if (v < 86_400) return `${v}s (${(v / 3600).toFixed(0)}h)`;
  return `${v}s (${(v / 86_400).toFixed(0)}d)`;
}

function formatRay(value: bigint): string {
  const dollarsTimes1e6 = (value * 1_000_000n) / RAY;
  const whole = dollarsTimes1e6 / 1_000_000n;
  const frac = dollarsTimes1e6 % 1_000_000n;
  return `${value} ($${whole}.${frac.toString().padStart(6, "0").slice(0, 4)})`;
}

function formatRayPerSecond(value: bigint): string {
  const perDay = value * SECONDS_PER_DAY;
  return `${value} (${formatRay(perDay)}/day)`;
}

function formatAssetWei(value: bigint, key?: string): string {
  const meta = inferAssetMeta(key);
  if (!meta) return value.toString();
  const scale = 10n ** BigInt(meta.decimals);
  const whole = value / scale;
  const frac = value % scale;
  if (frac === 0n) return `${value} (${whole.toLocaleString("en-US")} ${meta.symbol})`;
  const fracStr = frac.toString().padStart(meta.decimals, "0").replace(/0+$/, "");
  return `${value} (${whole.toLocaleString("en-US")}.${fracStr || "0"} ${meta.symbol})`;
}

function formatAssetWeiPerSecond(value: bigint, key?: string): string {
  const perDay = value * SECONDS_PER_DAY;
  return `${value} (${formatAssetWei(perDay, key).split(" (")[1]?.replace(")", "") ?? ""}/day)`;
}

function inferAssetMeta(key?: string): { decimals: number; symbol: string } | null {
  if (!key) return null;
  // Conventions: keys like "DepositPolicy.gho.capacity" or "SlippageCoverageVault.usdc.windowCap".
  for (const k of Object.keys(ASSET_META)) {
    if (key.toLowerCase().includes(`.${k}.`)) return ASSET_META[k]!;
  }
  return null;
}

/** Useful in renderers: produce a short status glyph (no emoji). */
export function statusGlyph(severity: string): string {
  switch (severity) {
    case "pass":
      return "✓";
    case "fail":
      return "✗";
    case "warning":
      return "!";
    case "skipped":
      return "·";
    case "error":
      return "?";
    default:
      return " ";
  }
}
