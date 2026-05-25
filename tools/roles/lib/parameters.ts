/**
 * Expands the hand-curated parameter spec against the three deployment configs and produces the
 * env-aware `ParameterJson[]` that lands in `script/output/roles.json`.
 *
 * Each leaf-value in `deployment-config.*.jsonc` becomes one row: per-asset specs expand to one
 * row per asset, per-chain specs to one row per chain. Every row carries both the literal config
 * value (`rawValueByEnv`) and a human-readable rendering (`humanValueByEnv`) so reviewers can
 * copy-paste the raw value without re-parsing a combined cell. The `jsonPath` column makes the
 * provenance — which key in which file — explicit.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { parse as parseJsonc } from "jsonc-parser";

import {
  ASSET_DECIMALS,
  ASSET_SYMBOL,
  PARAMETER_SPECS,
  type AssetKey,
  type ParameterSpec,
  type ValueFormat,
  type ValueSpec,
} from "./parameters-spec.js";
import { ENVS, type Env, type ParameterJson } from "./types.js";

export interface ConfigByEnv {
  staging: unknown;
  preprod: unknown;
  prod: unknown;
}

export function loadDeploymentConfigs(repoRoot: string): {
  configs: ConfigByEnv;
  sources: Record<Env, string>;
} {
  const configs = {} as ConfigByEnv;
  const sources = {} as Record<Env, string>;
  for (const env of ENVS) {
    const path = join(repoRoot, `config/deployment-config.${env}.jsonc`);
    const raw = readFileSync(path, "utf8");
    const errors: { error: number; offset: number; length: number }[] = [];
    const parsed = parseJsonc(raw, errors, { allowTrailingComma: true });
    if (errors.length > 0) {
      throw new Error(
        `Failed to parse ${path}: ${errors.length} JSONC error(s) — first at offset ${errors[0]!.offset}`,
      );
    }
    configs[env] = parsed;
    sources[env] = raw;
  }
  return { configs, sources };
}

export function buildParameters(configs: ConfigByEnv): ParameterJson[] {
  const out: ParameterJson[] = [];
  for (const spec of PARAMETER_SPECS) {
    if (spec.value.type === "scalar") {
      out.push(buildRow(spec, spec.value.path, "", spec.value.format, configs));
    } else {
      for (const asset of spec.value.assets) {
        const jsonPath = spec.value.pathTemplate.replace("{asset}", asset);
        out.push(buildRow(spec, jsonPath, asset, spec.value.format, configs));
      }
    }
  }
  return out;
}

function buildRow(
  spec: ParameterSpec,
  jsonPath: string,
  asset: AssetKey | "",
  format: ValueFormat,
  configs: ConfigByEnv,
): ParameterJson {
  const rawValueByEnv = {} as Record<Env, string>;
  const humanValueByEnv = {} as Record<Env, string>;
  for (const env of ENVS) {
    const raw = getByPath(configs[env], jsonPath);
    rawValueByEnv[env] = raw === undefined ? "(missing)" : formatRaw(raw);
    humanValueByEnv[env] =
      raw === undefined ? "(missing)" : formatHuman(raw, format, asset);
  }
  const assetLabel = asset ? ASSET_SYMBOL[asset] : "";
  const key = asset ? `${spec.key}[${assetLabel}]` : spec.key;
  return {
    key,
    jsonPath,
    contract: spec.contract,
    category: spec.category,
    chainContext: spec.chainContext,
    asset: assetLabel as ParameterJson["asset"],
    setterKeys: spec.setterKeys,
    unit: spec.unit,
    onChainLimits: spec.onChainLimits,
    rawValueByEnv,
    humanValueByEnv,
    status: "Active",
  };
}

function formatRaw(raw: unknown): string {
  if (raw === null) return "null";
  if (typeof raw === "boolean") return raw ? "true" : "false";
  if (typeof raw === "number" || typeof raw === "string") return String(raw);
  return JSON.stringify(raw);
}

function formatHuman(
  raw: unknown,
  format: ValueFormat,
  asset: AssetKey | "",
): string {
  const s = raw === null || raw === undefined ? "" : String(raw);
  switch (format) {
    case "raw":
      return s;
    case "bool":
      return raw === true ? "Yes" : raw === false ? "No" : s;
    case "address":
      return s;
    case "uint":
      return formatUint(s);
    case "bps":
      return humaniseBps(s);
    case "seconds":
      return humaniseSeconds(Number(raw));
    case "ray":
      return humaniseRay(s);
    case "rayPerSec":
      return humaniseRayPerSec(s);
    case "assetWei":
      if (!asset) return s;
      return humaniseAssetWei(s, asset);
    case "assetWeiPerSec":
      if (!asset) return s;
      return humaniseAssetWeiPerSec(s, asset);
    default:
      return s;
  }
}

function humaniseAssetWei(raw: string, asset: AssetKey): string {
  const decimals = ASSET_DECIMALS[asset];
  const symbol = ASSET_SYMBOL[asset];
  try {
    const whole = BigInt(raw) / BigInt(10) ** BigInt(decimals);
    return `${withThousandsSeparators(whole)} ${symbol}`;
  } catch {
    return `${raw} ${symbol}`;
  }
}

function humaniseAssetWeiPerSec(raw: string, asset: AssetKey): string {
  const decimals = ASSET_DECIMALS[asset];
  const symbol = ASSET_SYMBOL[asset];
  try {
    const perDay =
      (BigInt(raw) * BigInt(86400)) / BigInt(10) ** BigInt(decimals);
    return `${withThousandsSeparators(perDay)} ${symbol}/day`;
  } catch {
    return `${raw} ${symbol}/sec`;
  }
}

function humaniseRay(raw: string): string {
  try {
    const value = BigInt(raw);
    if (value === BigInt(0)) return "0";
    const RAY = BigInt(10) ** BigInt(27);
    const whole = value / RAY;
    const remainder = value % RAY;
    if (remainder === BigInt(0)) return `$${withThousandsSeparators(whole)}`;
    if (whole === BigInt(0)) {
      const fractional =
        remainder.toString().padStart(27, "0").replace(/0+$/, "") || "0";
      return `$0.${fractional}`;
    }
    return raw;
  } catch {
    return raw;
  }
}

function humaniseRayPerSec(raw: string): string {
  try {
    const value = BigInt(raw);
    if (value === BigInt(0)) return "0";
    const RAY = BigInt(10) ** BigInt(27);
    const perDay = (value * BigInt(86400)) / RAY;
    return `$${withThousandsSeparators(perDay)}/day`;
  } catch {
    return raw;
  }
}

function humaniseBps(raw: string): string {
  if (!/^[0-9]+$/.test(raw)) return raw;
  const bps = Number(raw);
  const pct = bps / 100;
  return `${pct % 1 === 0 ? pct.toFixed(0) : pct.toFixed(2)}%`;
}

function humaniseSeconds(seconds: number): string {
  if (!Number.isFinite(seconds)) return String(seconds);
  if (seconds === 0) return "0s";
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) {
    const m = seconds / 60;
    return `${trimFloat(m)} min`;
  }
  if (seconds < 86400) {
    const h = seconds / 3600;
    return `${trimFloat(h)} h`;
  }
  const d = seconds / 86400;
  return `${trimFloat(d)} d`;
}

function trimFloat(value: number): string {
  return Number.isInteger(value) ? value.toString() : value.toFixed(2);
}

function formatUint(raw: string): string {
  if (!/^[0-9]+$/.test(raw)) return raw;
  return withThousandsSeparators(BigInt(raw));
}

function withThousandsSeparators(value: bigint): string {
  const s = value.toString();
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function getByPath(obj: unknown, path: string): unknown {
  const segments = path.split(".");
  let cur: unknown = obj;
  for (const seg of segments) {
    if (cur === undefined || cur === null || typeof cur !== "object")
      return undefined;
    cur = (cur as Record<string, unknown>)[seg];
  }
  return cur;
}
