// Live probes - runtime invariants that aren't expressible as "JSONC value
// equals on-chain value" but are essential for proving the system can actually
// operate after deploy. All batched into a single multicall for efficiency.

import { type Address, type PublicClient, getAddress } from "viem";

import { tryEntry } from "../artefact.js";
import {
  CCIP_ROUTER_ABI,
  CHAIN_BALANCE_ORACLE_ABI,
  CHAINLINK_SEQUENCER_FEED_ABI,
  PRICE_ORACLE_ABI,
} from "../catalogue/abis.js";
import type { CheckResult, ChainKind, DeploymentArtefact, Env } from "../types.js";

const ASSETS = ["gho", "usdc", "usdt"] as const;
type Asset = (typeof ASSETS)[number];

export interface LiveProbeArgs {
  env: Env;
  chain: ChainKind;
  artefact: DeploymentArtefact;
  client: PublicClient;
  blockNumber: bigint;
  blockTimestamp: bigint;
  config: Record<string, unknown>;
}

interface ProbeCall {
  key: string;
  description: string;
  contract: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
  };
  verify: (raw: unknown, ctx: { blockTimestamp: bigint }) => CheckResult;
}

export async function runLiveProbes(args: LiveProbeArgs): Promise<CheckResult[]> {
  const { chain, artefact, client, blockNumber, blockTimestamp, config } = args;
  const chainKey = chain === "accounting" ? "accountingChain" : "earningChain";
  const chainConfig = (config[chainKey] ?? {}) as Record<string, unknown>;
  const remoteConfig = (config[chain === "accounting" ? "earningChain" : "accountingChain"] ?? {}) as Record<
    string,
    unknown
  >;
  const assets = (chainConfig.assets ?? {}) as Record<Asset, string>;
  const probes: ProbeCall[] = [];

  // ---- PriceOracle.getPrice(asset) > 0 ----
  const priceOracle = tryEntry(artefact, "PriceOracle");
  if (priceOracle) {
    for (const asset of ASSETS) {
      const assetAddr = assets[asset];
      if (!assetAddr) continue;
      probes.push({
        key: `PriceOracle.getPrice.${asset}`,
        description: "price oracle returns non-zero",
        contract: {
          address: priceOracle.address,
          abi: PRICE_ORACLE_ABI,
          functionName: "getPrice",
          args: [getAddress(assetAddr)],
        },
        verify: (raw) => {
          const v = raw as bigint;
          if (v === 0n) {
            return {
              group: "LiveProbes",
              key: `PriceOracle.getPrice.${asset}`,
              severity: "fail",
              expected: ">0 ray",
              actual: v,
              format: "ray",
              note: "oracle returned 0 - adapter stale or unset",
            };
          }
          return {
            group: "LiveProbes",
            key: `PriceOracle.getPrice.${asset}`,
            severity: "pass",
            expected: ">0 ray",
            actual: v,
            format: "ray",
          };
        },
      });
    }
  }

  // ---- ChainBalanceOracle.getChainBalance(remoteChainId).isStale == false ----
  if (chain === "accounting") {
    const chainBalanceOracle = tryEntry(artefact, "ChainBalanceOracle");
    const ecChainId = remoteConfig.chainId as number | string | undefined;
    if (chainBalanceOracle && ecChainId !== undefined) {
      probes.push({
        key: `ChainBalanceOracle.getChainBalance.${ecChainId}.fresh`,
        description: "chain balance oracle reports fresh",
        contract: {
          address: chainBalanceOracle.address,
          abi: CHAIN_BALANCE_ORACLE_ABI,
          functionName: "getChainBalance",
          args: [BigInt(ecChainId)],
        },
        verify: (raw, ctx) => {
          const cb = raw as {
            balanceRay: bigint;
            lastUpdateTimestamp: bigint;
            isStale: boolean;
            sourceChainBlockNumber: bigint;
          };
          if (cb.isStale) {
            const ageSeconds = ctx.blockTimestamp - cb.lastUpdateTimestamp;
            return {
              group: "LiveProbes",
              key: `ChainBalanceOracle.getChainBalance.${ecChainId}.fresh`,
              severity: "fail",
              expected: "isStale=false",
              actual: `isStale=true, age=${ageSeconds}s`,
              format: "raw",
              note: "oracle reports stale; system will treat earning-chain balance as 0",
            };
          }
          return {
            group: "LiveProbes",
            key: `ChainBalanceOracle.getChainBalance.${ecChainId}.fresh`,
            severity: "pass",
            expected: "isStale=false",
            actual: `isStale=false, block=${cb.sourceChainBlockNumber}`,
            format: "raw",
          };
        },
      });
    }
  }

  // ---- CCIPRouter.isChainSupported(counterpartySelector) ----
  const ccipRouterAddrStr = chainConfig.ccipRouterAddress as string | undefined;
  const counterpartySelector = remoteConfig.ccipSelector as string | undefined;
  if (ccipRouterAddrStr && counterpartySelector) {
    probes.push({
      key: `CCIPRouter.isChainSupported.${counterpartySelector}`,
      description: "CCIP router supports the counterparty chain",
      contract: {
        address: getAddress(ccipRouterAddrStr),
        abi: CCIP_ROUTER_ABI,
        functionName: "isChainSupported",
        args: [BigInt(counterpartySelector)],
      },
      verify: (raw) => {
        const ok = raw as boolean;
        return {
          group: "LiveProbes",
          key: `CCIPRouter.isChainSupported.${counterpartySelector}`,
          severity: ok ? "pass" : "fail",
          expected: true,
          actual: ok,
          format: "bool",
          ...(ok ? {} : { note: "CCIP router does not support counterparty chain selector" }),
        };
      },
    });
  }

  // ---- L2 sequencer uptime feed (accounting chain only, when not mocked) ----
  if (chain === "accounting") {
    const useMock = chainConfig.useMockSequencerUptimeFeed as boolean | undefined;
    const sequencerFeedAddrStr = chainConfig.sequencerUptimeFeed as string | undefined;
    if (!useMock && sequencerFeedAddrStr) {
      probes.push({
        key: "Chainlink.sequencerUptimeFeed.up",
        description: "L2 sequencer uptime feed reports up (answer == 0)",
        contract: {
          address: getAddress(sequencerFeedAddrStr),
          abi: CHAINLINK_SEQUENCER_FEED_ABI,
          functionName: "latestRoundData",
        },
        verify: (raw, ctx) => {
          // Chainlink sequencer feed: answer = 0 means "up", answer != 0 means "down".
          const data = raw as readonly [bigint, bigint, bigint, bigint, bigint];
          const answer = data[1];
          const startedAt = data[2];
          const ageSeconds = ctx.blockTimestamp > startedAt ? ctx.blockTimestamp - startedAt : 0n;
          // Matches L2ChainlinkOracleAdapter.GRACE_PERIOD_TIME_SECONDS: the feed is only "healthy"
          // once the sequencer has been up for >= the grace period. Until then the L2 oracle still
          // treats prices as stale (validatePrice reverts), so "answer==0" alone isn't enough.
          const GRACE_PERIOD_SECONDS = 7200n;
          if (answer !== 0n) {
            return {
              group: "LiveProbes",
              key: "Chainlink.sequencerUptimeFeed.up",
              severity: "fail",
              expected: "answer=0 (up)",
              actual: `answer=${answer}, startedAt=${startedAt}`,
              format: "raw",
              note: "sequencer reports down - withdrawals may revert via L2 oracle staleness",
            };
          }
          if (ageSeconds < GRACE_PERIOD_SECONDS) {
            // Transient (clears once the grace period elapses) - warn rather than block the gate.
            return {
              group: "LiveProbes",
              key: "Chainlink.sequencerUptimeFeed.up",
              severity: "warning",
              expected: `up + grace elapsed (>=${GRACE_PERIOD_SECONDS}s)`,
              actual: `up but only ${ageSeconds}s since recovery`,
              format: "raw",
              note: "sequencer up but within the grace period - the L2 oracle still treats prices as stale until it elapses",
            };
          }
          return {
            group: "LiveProbes",
            key: "Chainlink.sequencerUptimeFeed.up",
            severity: "pass",
            expected: "answer=0, grace elapsed",
            actual: `answer=0, age=${ageSeconds}s`,
            format: "raw",
          };
        },
      });
    }
  }

  if (probes.length === 0) return [];

  // Run all probes via a single multicall for batching.
  const results = await client.multicall({
    contracts: probes.map((p) => p.contract) as unknown as Parameters<typeof client.multicall>[0]["contracts"],
    blockNumber,
    allowFailure: true,
  });

  return probes.map((probe, i) => {
    const r = results[i]!;
    if (r.status === "failure") {
      return {
        group: "LiveProbes",
        key: probe.key,
        severity: "error",
        format: "raw",
        note: `probe call reverted: ${r.error?.message ?? "unknown"}`,
      };
    }
    return probe.verify(r.result, { blockTimestamp });
  });
}
