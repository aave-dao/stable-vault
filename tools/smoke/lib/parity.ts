// Generic parity engine. A getter spec pairs a JSONC leaf with a contract
// getter; the engine reads on-chain values in parallel via viem multicall,
// compares them, and emits a CheckResult per leaf.
//
// Adding a new parameter to config/deployment-config.<env>.jsonc requires only
// adding one entry to lib/catalogue/getters.ts — no engine changes.

import type { Abi, Address, PublicClient } from "viem";

import type { CheckResult, ValueFormat } from "./types.js";

export interface GetterSpec {
  /** Group label used to bucket results in the renderer (e.g. "DepositPolicy"). */
  group: string;
  /** Stable key identifying the check (e.g. "DepositPolicy.gho.capacity"). */
  key: string;
  /** Address of the contract to call. */
  address: Address;
  /** ABI fragment for the function being called. */
  abi: Abi;
  /** Function name on the ABI. */
  functionName: string;
  /** Args for the call. */
  args?: readonly unknown[];
  /** Expected value, already coerced to the comparable shape. */
  expected: unknown;
  /** How to render expected + actual in the output. */
  format: ValueFormat;
  /**
   * Optional projector that extracts the field of interest from the raw on-chain
   * return value (e.g. picks `bucket.capacity` from a struct return).
   */
  pick?: (raw: unknown) => unknown;
  /** Optional comparator override. Default is BigInt-aware equality. */
  equals?: (expected: unknown, actual: unknown) => boolean;
  /** When set, the check is reported as `skipped` with this note (e.g. TBD placeholder). */
  skipIf?: { reason: string };
}

interface RunArgs {
  client: PublicClient;
  blockNumber: bigint;
  specs: GetterSpec[];
}

export async function runParity({ client, blockNumber, specs }: RunArgs): Promise<CheckResult[]> {
  const activeSpecs = specs.filter((s) => !s.skipIf);
  const skipped: CheckResult[] = specs
    .filter((s) => s.skipIf)
    .map((s) => ({
      group: s.group,
      key: s.key,
      severity: "skipped" as const,
      expected: s.expected,
      format: s.format,
      note: s.skipIf!.reason,
    }));

  if (activeSpecs.length === 0) return skipped;

  const calls = activeSpecs.map((s) => ({
    address: s.address,
    abi: s.abi,
    functionName: s.functionName,
    args: s.args,
  }));

  const raw = await client.multicall({
    contracts: calls,
    blockNumber,
    allowFailure: true,
  });

  const results: CheckResult[] = raw.map((r, i) => {
    const spec = activeSpecs[i]!;
    if (r.status === "failure") {
      return {
        group: spec.group,
        key: spec.key,
        severity: "error",
        expected: spec.expected,
        actual: undefined,
        format: spec.format,
        note: `getter reverted: ${r.error?.message ?? "unknown"}`,
      };
    }
    const picked = spec.pick ? spec.pick(r.result) : r.result;
    const match = (spec.equals ?? defaultEquals)(spec.expected, picked);
    return {
      group: spec.group,
      key: spec.key,
      severity: match ? "pass" : "fail",
      expected: spec.expected,
      actual: picked,
      format: spec.format,
      ...(match ? {} : { note: "config-to-on-chain mismatch" }),
    };
  });

  return [...results, ...skipped];
}

function defaultEquals(expected: unknown, actual: unknown): boolean {
  if (typeof expected === "bigint" || typeof actual === "bigint") {
    try {
      return toBig(expected) === toBig(actual);
    } catch {
      return false;
    }
  }
  if (typeof expected === "string" && typeof actual === "string") {
    return expected.toLowerCase() === actual.toLowerCase();
  }
  return expected === actual;
}

function toBig(v: unknown): bigint {
  if (typeof v === "bigint") return v;
  if (typeof v === "number") return BigInt(v);
  if (typeof v === "string") return BigInt(v);
  throw new Error(`cannot coerce ${typeof v} to bigint`);
}
