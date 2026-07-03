// Resolve the RPC URL for a (env, chain) pair and build a viem public client
// tuned for ~200 reads against a single endpoint via multicall3 batching.
//
// RPC URLs come from env vars (default convention `SMOKE_RPC_<ENV>_<NETWORK>`,
// e.g. `SMOKE_RPC_STAGING_ARBITRUM`; per-chain `rpcEnvVar` override in
// tools/smoke/networks.json) or `--rpc <url>` CLI override. We never log the
// full URL - only the host portion - so secrets in URLs don't leak into stdout
// or the JSON report.

import { createPublicClient, http, type Address, type PublicClient } from "viem";

import { chainById } from "./chains.js";
import type { ChainKind, Env } from "./types.js";

export interface RpcConfig {
  url: string;
  /** Masked form safe to log: scheme + host only, no path or query. */
  masked: string;
  chainKind: ChainKind;
  /** Network label from networks.json (lowercase: "arbitrum", "ethereum", …). */
  network: string;
  env: Env;
  /** Expected chain id from JSONC config. Used to bind the viem client to a chain definition. */
  expectedChainId: number;
}

export interface ResolveRpcArgs {
  env: Env;
  kind: ChainKind;
  network: string;
  /** Env var name to look up when `override` is not set. */
  rpcEnvVar: string;
  expectedChainId: number;
  /** Explicit --rpc CLI override; bypasses env var lookup. */
  override?: string;
}

export function resolveRpc(args: ResolveRpcArgs): RpcConfig {
  const url = args.override ?? process.env[args.rpcEnvVar] ?? "";
  if (!url) {
    throw new Error(
      `No RPC URL configured. Set ${args.rpcEnvVar} or pass --rpc <url>.`,
    );
  }
  return {
    url,
    masked: maskUrl(url),
    chainKind: args.kind,
    network: args.network,
    env: args.env,
    expectedChainId: args.expectedChainId,
  };
}

export function makeClient(rpc: RpcConfig): PublicClient {
  return createPublicClient({
    chain: chainById(rpc.expectedChainId),
    transport: http(rpc.url, { retryCount: 3, retryDelay: 1000, batch: true }),
    batch: { multicall: { wait: 16, batchSize: 4096 } },
  });
}

export async function captureBlock(client: PublicClient): Promise<{ blockNumber: bigint; timestamp: bigint }> {
  const block = await client.getBlock({ blockTag: "latest" });
  return { blockNumber: block.number, timestamp: block.timestamp };
}

function maskUrl(url: string): string {
  try {
    const u = new URL(url);
    return `${u.protocol}//${u.host}`;
  } catch {
    return "(unparseable RPC URL)";
  }
}

/** Sanity check that the connected RPC reports the chain id we expect for this env. */
export async function assertChainId(client: PublicClient, expected: number): Promise<number> {
  const actual = await client.getChainId();
  if (actual !== expected) {
    throw new Error(`RPC chain id mismatch: expected ${expected}, got ${actual}`);
  }
  return actual;
}

/** Re-export Address for convenience inside checks/. */
export type { Address };
