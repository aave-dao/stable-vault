// Resolve the RPC URL for an (env, chain) tuple and build a viem public client
// with multicall batching tuned for ~150 reads against a single endpoint.
//
// RPC URLs come from env vars (SMOKE_RPC_<ENV>_<CHAIN>) or --rpc <url> CLI override.
// We never log the full URL — only the host portion — so secrets in URLs don't
// leak into stdout or the JSON report.

import { createPublicClient, http, type Address, type PublicClient } from "viem";

import type { ChainKind, Env } from "./types.js";

export interface RpcConfig {
  url: string;
  /** Masked form safe to log: scheme + host only, no path or query. */
  masked: string;
  chainKind: ChainKind;
  env: Env;
}

export function resolveRpc(env: Env, chain: ChainKind, override?: string): RpcConfig {
  const url = override ?? process.env[`SMOKE_RPC_${env.toUpperCase()}_${chain.toUpperCase()}`] ?? "";
  if (!url) {
    throw new Error(
      `No RPC URL configured. Set SMOKE_RPC_${env.toUpperCase()}_${chain.toUpperCase()} or pass --rpc <url>.`,
    );
  }
  return { url, masked: maskUrl(url), chainKind: chain, env };
}

export function makeClient(rpc: RpcConfig): PublicClient {
  return createPublicClient({
    transport: http(rpc.url, { batch: { wait: 16 } }),
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
