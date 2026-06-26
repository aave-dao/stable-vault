// tools/smoke/run.ts — smoke harness CLI entrypoint.
//
// Reads JSONC config + deployment artefact, runs topology + parity + (TODO) live
// probes against a live or forked RPC, prints a terminal report in the user's
// chosen mode, and writes a dated JSON report under tools/smoke/output/.
//
// Usage:
//   tsx tools/smoke/run.ts --env preprod --chain accounting [--rpc <url>] [--summary|--quiet|--json] [--strict]

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parse as parseJsonc } from "jsonc-parser";
import { keccak256, toHex, type Address, type Hex } from "viem";

import { loadArtefact } from "./lib/artefact.js";
import { runLiveProbes } from "./lib/checks/live-probes.js";
import { runTopology } from "./lib/checks/topology.js";
import { buildGetterSpecs } from "./lib/catalogue/getters.js";
import { loadNetworks, resolveChainEntry, rpcEnvVarFor } from "./lib/networks.js";
import { runParity } from "./lib/parity.js";
import { render } from "./lib/render.js";
import { buildReport, writeReport } from "./lib/report.js";
import { assertChainId, captureBlock, makeClient, resolveRpc } from "./lib/rpc.js";
import {
  CHAIN_KINDS,
  ENVS,
  EXIT_CODES,
  type ChainKind,
  type Env,
  type RenderMode,
  type RunMeta,
} from "./lib/types.js";

const REPO_ROOT = process.cwd();

interface Args {
  env: Env;
  chain: ChainKind;
  network?: string;
  rpc?: string;
  mode: RenderMode;
  strict: boolean;
  noLiveProbes: boolean;
}

function parseArgs(argv: string[]): Args {
  let env: Env | undefined;
  let chain: ChainKind | undefined;
  let network: string | undefined;
  let rpc: string | undefined;
  let mode: RenderMode = "full";
  let strict = false;
  let noLiveProbes = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "--env":
        env = requireEnv(argv[++i]);
        break;
      case "--chain":
        chain = requireChain(argv[++i]);
        break;
      case "--network":
        network = argv[++i];
        break;
      case "--rpc":
        rpc = argv[++i];
        break;
      case "--summary":
        mode = "summary";
        break;
      case "--quiet":
        mode = "quiet";
        break;
      case "--json":
        mode = "json";
        break;
      case "--strict":
        strict = true;
        break;
      case "--no-live-probes":
        noLiveProbes = true;
        break;
      case "-h":
      case "--help":
        printHelp();
        process.exit(0);
      default:
        if (a?.startsWith("--")) throw new Error(`Unknown flag: ${a}`);
    }
  }
  if (!env || !chain) {
    printHelp();
    throw new Error("--env <preprod|staging|prod> and --chain <accounting|earning> are required");
  }
  return { env, chain, network, rpc, mode, strict, noLiveProbes };
}

function requireEnv(v: string | undefined): Env {
  if (!v || !(ENVS as readonly string[]).includes(v)) {
    throw new Error(`--env must be one of: ${ENVS.join(", ")}`);
  }
  return v as Env;
}

function requireChain(v: string | undefined): ChainKind {
  if (!v || !(CHAIN_KINDS as readonly string[]).includes(v)) {
    throw new Error(`--chain must be one of: ${CHAIN_KINDS.join(", ")}`);
  }
  return v as ChainKind;
}

function printHelp(): void {
  process.stderr.write(
    [
      "Usage: tsx tools/smoke/run.ts --env <env> --chain <chain> [flags]",
      "",
      "Required:",
      "  --env <staging|preprod|prod>",
      "  --chain <accounting|earning>",
      "",
      "Flags:",
      "  --rpc <url>          override default RPC URL",
      "  --summary            compact one-line-per-group view",
      "  --quiet              failures only",
      "  --json               machine-readable output (no stdout colours)",
      "  --strict             warnings (e.g. TBD placeholders) become failures",
      "  --no-live-probes     skip oracle / CCIP live calls",
      "",
      "RPC URL also resolved from SMOKE_RPC_<ENV>_<CHAIN> env var.",
      "",
    ].join("\n"),
  );
}

interface LoadedConfig {
  config: Record<string, unknown>;
  configPath: string;
  configSha: Hex;
  deployer: Address;
  expectedChainId: number;
}

function loadConfig(env: Env, chain: ChainKind): LoadedConfig {
  const configPath = resolve(REPO_ROOT, `config/deployment-config.${env}.jsonc`);
  const raw = readFileSync(configPath, "utf8");
  const config = parseJsonc(raw) as Record<string, unknown>;
  const deployer = config.deployer as Address;
  if (!deployer) throw new Error(`config/deployment-config.${env}.jsonc: missing "deployer"`);
  const chainKey = chain === "accounting" ? "accountingChain" : "earningChain";
  const chainConfig = config[chainKey] as { chainId?: number | string } | undefined;
  if (!chainConfig?.chainId) throw new Error(`config: missing ${chainKey}.chainId`);
  return {
    config,
    configPath,
    configSha: keccak256(toHex(raw)),
    deployer,
    expectedChainId: Number(chainConfig.chainId),
  };
}

function gitCommit(): string {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], { cwd: REPO_ROOT, encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
}

async function main(): Promise<number> {
  const start = Date.now();
  const args = parseArgs(process.argv.slice(2));

  const networks = loadNetworks(REPO_ROOT);
  const chainEntry = resolveChainEntry(networks, args.env, args.chain, args.network);

  const loaded = loadConfig(args.env, args.chain);
  const artefact = loadArtefact(args.env, args.chain, chainEntry.network, REPO_ROOT);
  const rpc = resolveRpc({
    env: args.env,
    kind: args.chain,
    network: chainEntry.network,
    rpcEnvVar: rpcEnvVarFor(args.env, chainEntry),
    expectedChainId: loaded.expectedChainId,
    override: args.rpc,
  });
  const client = makeClient(rpc);

  let chainId: number;
  try {
    chainId = await assertChainId(client, loaded.expectedChainId);
  } catch (e) {
    process.stderr.write(`RPC error: ${(e as Error).message}\n`);
    return EXIT_CODES.rpcError;
  }

  const { blockNumber, timestamp } = await captureBlock(client);

  const meta: RunMeta = {
    env: args.env,
    chain: args.chain,
    network: chainEntry.network,
    chainId,
    rpcUrlMasked: rpc.masked,
    blockNumber,
    blockTimestamp: timestamp,
    commit: gitCommit(),
    configPath: loaded.configPath,
    configSha: loaded.configSha,
    artefactPath: artefact.rawPath,
    artefactSha: artefact.rawSha,
    startedAt: new Date().toISOString(),
  };

  const topology = await runTopology({
    artefact,
    deployer: loaded.deployer,
    client,
    blockNumber,
    repoRoot: REPO_ROOT,
  });

  const getterSpecs = buildGetterSpecs({
    env: args.env,
    chain: args.chain,
    config: loaded.config,
    artefact,
    deployer: loaded.deployer,
    repoRoot: REPO_ROOT,
  });
  const parity = await runParity({ client, blockNumber, specs: getterSpecs });

  const liveProbes = args.noLiveProbes
    ? []
    : await runLiveProbes({
        env: args.env,
        chain: args.chain,
        artefact,
        client,
        blockNumber,
        blockTimestamp: timestamp,
        config: loaded.config,
      });

  let results = [...topology, ...parity, ...liveProbes];
  if (args.strict) {
    results = results.map((r) => (r.severity === "warning" ? { ...r, severity: "fail" as const } : r));
  }

  const durationMs = Date.now() - start;
  const report = buildReport(meta, results, durationMs);

  if (args.mode === "json") {
    process.stdout.write(render(report, "json") + "\n");
  } else {
    process.stdout.write(render(report, args.mode) + "\n");
  }

  const reportPath = writeReport(report, REPO_ROOT);
  if (args.mode !== "json") {
    process.stdout.write(`Report: ${reportPath}\n`);
  }

  // A confirmed parity fail is real drift and must win over a (possibly transient) RPC error —
  // otherwise one reverting getter masks the drift and mislabels it as "RPC, retry". Check fail first.
  if (report.summary.fail > 0) {
    // Distinguish "predicted address has no code" (incomplete deploy) from generic parity fails.
    const incomplete = results.some((r) => r.key.endsWith(".code") && r.severity === "fail");
    return incomplete ? EXIT_CODES.incompleteDeploy : EXIT_CODES.parityFail;
  }
  if (report.summary.error > 0) return EXIT_CODES.rpcError;
  return EXIT_CODES.pass;
}

main()
  .then((code) => process.exit(code))
  .catch((err: Error) => {
    process.stderr.write(`smoke: fatal ${err.stack ?? err.message}\n`);
    process.exit(EXIT_CODES.configError);
  });
