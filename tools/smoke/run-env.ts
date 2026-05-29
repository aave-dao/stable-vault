// tools/smoke/run-env.ts — multi-chain orchestrator.
//
// Runs the smoke harness against every chain configured for an env in
// tools/smoke/networks.json, in parallel. Subprocess outputs are buffered and
// printed sequentially with per-chain banners so the operator gets a clean,
// readable report instead of interleaved streams. Exit code is the worst of
// the per-chain exits.
//
// Usage:
//   tsx tools/smoke/run-env.ts --env <staging|preprod|prod> [pass-through flags…]
//
// Pass-through flags (forwarded to each per-chain run.ts):
//   --summary | --quiet | --json | --strict | --no-live-probes

import { spawn } from "node:child_process";

import { loadNetworks, rpcEnvVarFor, type ChainEntry } from "./lib/networks.js";
import { ENVS, EXIT_CODES, type Env } from "./lib/types.js";

const REPO_ROOT = process.cwd();

interface ParsedArgs {
  env: Env;
  passthrough: string[];
}

function parseArgs(argv: string[]): ParsedArgs {
  let env: Env | undefined;
  const passthrough: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === undefined) continue;
    if (a === "--env") {
      const v = argv[++i];
      if (!v || !(ENVS as readonly string[]).includes(v)) {
        throw new Error(`--env must be one of: ${ENVS.join(", ")}`);
      }
      env = v as Env;
    } else if (a === "-h" || a === "--help") {
      printHelp();
      process.exit(0);
    } else if (a === "--chain") {
      throw new Error("--chain is not accepted here; run-env.ts runs all chains for the env. Use run.ts for a single chain.");
    } else {
      // Forward anything we don't recognise to the per-chain subprocess.
      passthrough.push(a);
    }
  }

  if (!env) {
    printHelp();
    throw new Error("--env <staging|preprod|prod> is required");
  }
  return { env, passthrough };
}

function printHelp(): void {
  process.stderr.write(
    [
      "Usage: tsx tools/smoke/run-env.ts --env <env> [flags]",
      "",
      "Required:",
      "  --env <staging|preprod|prod>",
      "",
      "Pass-through flags (forwarded to each per-chain run.ts):",
      "  --summary            compact one-line-per-group view",
      "  --quiet              failures only",
      "  --json               machine-readable output",
      "  --strict             warnings (e.g. TBD placeholders) become failures",
      "  --no-live-probes     skip oracle / CCIP live calls",
      "",
      "Per-chain RPC URLs are resolved from SMOKE_RPC_<ENV>_<KIND> env vars",
      "(see .env.example). Loaded automatically from .env when present.",
      "",
    ].join("\n"),
  );
}

interface ChainOutcome {
  kind: string;
  network: string;
  exitCode: number;
  stdout: string;
  stderr: string;
  durationMs: number;
}

function runChain(env: Env, chain: ChainEntry, passthrough: string[]): Promise<ChainOutcome> {
  // Resolve the RPC URL centrally (so multi-EC chains in the same env don't collide
  // on a single SMOKE_RPC_<ENV>_<KIND> variable). Pass it through as --rpc so the
  // subprocess doesn't need its own networks.json lookup.
  const envVar = rpcEnvVarFor(env, chain);
  const url = process.env[envVar];
  const rpcArgs = url ? ["--rpc", url] : [];

  const args = [
    "tools/smoke/run.ts",
    "--env",
    env,
    "--chain",
    chain.kind,
    "--network",
    chain.network,
    ...rpcArgs,
    ...passthrough,
  ];
  const started = Date.now();

  return new Promise((resolveOutcome) => {
    const child = spawn("tsx", args, {
      cwd: REPO_ROOT,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => out.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => err.push(chunk));

    child.on("close", (code) => {
      resolveOutcome({
        kind: chain.kind,
        network: chain.network,
        exitCode: code ?? 1,
        stdout: Buffer.concat(out).toString("utf8"),
        stderr: Buffer.concat(err).toString("utf8"),
        durationMs: Date.now() - started,
      });
    });

    child.on("error", (e) => {
      resolveOutcome({
        kind: chain.kind,
        network: chain.network,
        exitCode: EXIT_CODES.configError,
        stdout: "",
        stderr: `spawn error: ${e.message}\n`,
        durationMs: Date.now() - started,
      });
    });
  });
}

function banner(label: string): string {
  const line = "=".repeat(Math.max(8, label.length + 4));
  return `\n${line}\n  ${label}\n${line}\n`;
}

async function main(): Promise<number> {
  const args = parseArgs(process.argv.slice(2));
  const networks = loadNetworks(REPO_ROOT);
  const envEntry = networks[args.env];
  if (!envEntry) {
    process.stderr.write(`networks.json: no entry for env "${args.env}"\n`);
    return EXIT_CODES.configError;
  }
  if (!envEntry.chains.length) {
    process.stderr.write(`networks.json: env "${args.env}" has no chains configured\n`);
    return EXIT_CODES.configError;
  }

  process.stdout.write(
    `Running smoke for env=${args.env} (rpcSource=${envEntry.rpcSource}) across ${envEntry.chains.length} chain(s): ` +
      `${envEntry.chains.map((c) => `${c.kind}/${c.network}`).join(", ")}\n`,
  );

  // Parallel execution. Buffer per-chain output, then print sequentially in
  // declaration order so the operator gets a clean, predictable report.
  const outcomes = await Promise.all(envEntry.chains.map((c) => runChain(args.env, c, args.passthrough)));

  for (const outcome of outcomes) {
    process.stdout.write(banner(`${args.env} · ${outcome.kind} · ${outcome.network}  (exit ${outcome.exitCode}, ${(outcome.durationMs / 1000).toFixed(1)}s)`));
    if (outcome.stdout) process.stdout.write(outcome.stdout);
    if (outcome.stderr) process.stderr.write(outcome.stderr);
  }

  // Aggregate. Worst-of exit code, with a preference for the most informative
  // failure category: parityFail > incompleteDeploy > rpcError > configError > pass.
  const severity: Record<number, number> = {
    [EXIT_CODES.pass]: 0,
    [EXIT_CODES.configError]: 1,
    [EXIT_CODES.rpcError]: 2,
    [EXIT_CODES.incompleteDeploy]: 3,
    [EXIT_CODES.parityFail]: 4,
  };
  const worst = outcomes.reduce<number>((acc, o) => {
    const candidate = severity[o.exitCode] ?? 5;
    return candidate > (severity[acc] ?? -1) ? o.exitCode : acc;
  }, EXIT_CODES.pass);

  const passCount = outcomes.filter((o) => o.exitCode === EXIT_CODES.pass).length;
  process.stdout.write(`\n${passCount}/${outcomes.length} chains passed. Aggregate exit code: ${worst}\n`);
  return worst;
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    process.stderr.write(`run-env.ts: ${(e as Error).message}\n`);
    process.exit(EXIT_CODES.configError);
  });
