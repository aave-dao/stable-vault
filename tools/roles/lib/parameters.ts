/**
 * Resolves the hand-curated parameter spec against the three deployment configs and produces the
 * env-aware `ParameterJson[]` that lands in `script/output/roles.json`. The format helpers turn raw
 * config values (wei, RAY, bool, address) into the strings reviewers expect to see in Notion.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { parse as parseJsonc } from "jsonc-parser";

import { ASSET_DECIMALS, ASSET_SYMBOL, PARAMETER_SPECS, type AssetKey, type ParameterSpec, type ValueSpec } from "./parameters-spec.js";
import { ENVS, type Env, type ParameterJson } from "./types.js";

export interface ConfigByEnv {
  staging: unknown;
  preprod: unknown;
  prod: unknown;
}

export function loadDeploymentConfigs(repoRoot: string): { configs: ConfigByEnv; sources: Record<Env, string> } {
  const configs = {} as ConfigByEnv;
  const sources = {} as Record<Env, string>;
  for (const env of ENVS) {
    const path = join(repoRoot, `config/deployment-config.${env}.jsonc`);
    const raw = readFileSync(path, "utf8");
    const errors: { error: number; offset: number; length: number }[] = [];
    const parsed = parseJsonc(raw, errors, { allowTrailingComma: true });
    if (errors.length > 0) {
      throw new Error(`Failed to parse ${path}: ${errors.length} JSONC error(s) — first at offset ${errors[0]!.offset}`);
    }
    configs[env] = parsed;
    sources[env] = raw;
  }
  return { configs, sources };
}

export function buildParameters(configs: ConfigByEnv): ParameterJson[] {
  const out: ParameterJson[] = [];
  for (const spec of PARAMETER_SPECS) {
    const valueByEnv = {} as Record<Env, string>;
    for (const env of ENVS) {
      valueByEnv[env] = formatValue(spec.value, configs[env], spec);
    }
    out.push({
      key: spec.key,
      contract: spec.contract,
      category: spec.category,
      chainContext: spec.chainContext,
      setterKeys: spec.setterKeys,
      unit: spec.unit,
      onChainLimits: spec.onChainLimits,
      valueByEnv,
      status: "Active",
    });
  }
  return out;
}

function formatValue(value: ValueSpec, config: unknown, spec: ParameterSpec): string {
  if (value.type === "constant") return value.raw;

  if (value.type === "scalar") {
    const raw = getByPath(config, value.path);
    if (raw === undefined) return "(missing)";
    return formatScalar(raw, value.format);
  }

  // perAsset
  const parts: string[] = [];
  for (const asset of value.assets) {
    const path = value.pathTemplate.replace("{asset}", asset);
    const raw = getByPath(config, path);
    if (raw === undefined) {
      parts.push(`${ASSET_SYMBOL[asset]}: (missing)`);
      continue;
    }
    parts.push(formatAssetValue(raw, asset, value.format));
  }
  return parts.join(" / ");
}

function formatScalar(raw: unknown, format: string): string {
  switch (format) {
    case "raw":
      return String(raw);
    case "bool":
      return raw === true ? "true" : raw === false ? "false" : String(raw);
    case "address":
      return String(raw);
    case "uint":
      return formatUint(String(raw));
    case "bps":
      return `${formatUint(String(raw))} bps`;
    case "seconds":
      return humaniseSeconds(Number(raw));
    case "ray":
      return humaniseRay(String(raw));
    case "assetWei":
      return String(raw); // assetWei in scalar context falls back to raw
    default:
      return String(raw);
  }
}

function formatAssetValue(raw: unknown, asset: AssetKey, format: "assetWei" | "raw" | "seconds"): string {
  const symbol = ASSET_SYMBOL[asset];
  if (format === "raw") return `${symbol}: ${String(raw)}`;
  if (format === "seconds") return `${symbol}: ${humaniseSeconds(Number(raw))}`;
  return formatAssetWei(String(raw), asset);
}

function formatAssetWei(raw: string, asset: AssetKey): string {
  const decimals = ASSET_DECIMALS[asset];
  const symbol = ASSET_SYMBOL[asset];
  try {
    const whole = scaleDownBigInt(BigInt(raw), decimals);
    return `${withThousandsSeparators(whole)} ${symbol}`;
  } catch {
    return `${raw} ${symbol}`;
  }
}

function humaniseRay(raw: string): string {
  // RAY = 1e27. Show whole-dollar amounts as "$N (raw)" and sub-dollar amounts as "X.YYY (raw)";
  // leave per-second rates (close to 1 RAY with a fractional tail) as raw to avoid a misleading "~$1" tag.
  try {
    const value = BigInt(raw);
    if (value === BigInt(0)) return "0";
    const RAY = BigInt(10) ** BigInt(27);
    const whole = value / RAY;
    const remainder = value % RAY;
    if (remainder === BigInt(0)) return `$${withThousandsSeparators(whole)} (${raw})`;
    if (whole === BigInt(0)) {
      const fractional = remainder.toString().padStart(27, "0").replace(/0+$/, "") || "0";
      return `0.${fractional} (${raw})`;
    }
    return raw;
  } catch {
    return raw;
  }
}

function humaniseSeconds(seconds: number): string {
  if (!Number.isFinite(seconds)) return String(seconds);
  if (seconds === 0) return "0s";
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) {
    const m = seconds / 60;
    return `${Number.isInteger(m) ? m : m.toFixed(2)} min (${seconds}s)`;
  }
  if (seconds < 86400) {
    const h = seconds / 3600;
    return `${Number.isInteger(h) ? h : h.toFixed(2)} h (${seconds}s)`;
  }
  const d = seconds / 86400;
  return `${Number.isInteger(d) ? d : d.toFixed(2)} d (${seconds}s)`;
}

function formatUint(raw: string): string {
  if (!/^[0-9]+$/.test(raw)) return raw;
  return withThousandsSeparators(BigInt(raw));
}

function scaleDownBigInt(value: bigint, decimals: number): bigint {
  if (decimals <= 0) return value;
  return value / BigInt(10) ** BigInt(decimals);
}

function withThousandsSeparators(value: bigint): string {
  const s = value.toString();
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function getByPath(obj: unknown, path: string): unknown {
  const segments = path.split(".");
  let cur: unknown = obj;
  for (const seg of segments) {
    if (cur === undefined || cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[seg];
  }
  return cur;
}
