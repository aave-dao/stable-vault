// Parity engine tests use mock multicall results to avoid hitting an RPC.
// We verify the engine maps multicall return shapes to CheckResult correctly.

import { describe, expect, it } from "vitest";

import { runParity, type GetterSpec } from "../lib/parity.js";
import { DEPOSIT_POLICY_ABI } from "../lib/catalogue/abis.js";

const ADDR = "0x0000000000000000000000000000000000000001" as const;

function mockClient(returns: Array<{ status: "success"; result: unknown } | { status: "failure"; error: Error }>): any {
  return {
    multicall: async () => returns,
  };
}

describe("runParity", () => {
  it("emits pass when on-chain matches expected", async () => {
    const spec: GetterSpec = {
      group: "DepositPolicy",
      key: "DepositPolicy.gho.capacity",
      address: ADDR,
      abi: DEPOSIT_POLICY_ABI,
      functionName: "getDepositLimit",
      args: [ADDR],
      expected: 500n,
      format: "assetWei",
      pick: (raw) => (raw as { capacity: bigint }).capacity,
    };
    const client = mockClient([{ status: "success", result: { capacity: 500n, refillRate: 0n } }]);
    const results = await runParity({ client, blockNumber: 1n, specs: [spec] });
    expect(results).toHaveLength(1);
    expect(results[0]!.severity).toBe("pass");
    expect(results[0]!.actual).toBe(500n);
  });

  it("emits fail when on-chain diverges from expected", async () => {
    const spec: GetterSpec = {
      group: "DepositPolicy",
      key: "DepositPolicy.gho.capacity",
      address: ADDR,
      abi: DEPOSIT_POLICY_ABI,
      functionName: "getDepositLimit",
      args: [ADDR],
      expected: 500n,
      format: "assetWei",
      pick: (raw) => (raw as { capacity: bigint }).capacity,
    };
    const client = mockClient([{ status: "success", result: { capacity: 1_000_000n, refillRate: 0n } }]);
    const results = await runParity({ client, blockNumber: 1n, specs: [spec] });
    expect(results[0]!.severity).toBe("fail");
    expect(results[0]!.actual).toBe(1_000_000n);
  });

  it("emits error on multicall failure", async () => {
    const spec: GetterSpec = {
      group: "DepositPolicy",
      key: "DepositPolicy.gho.capacity",
      address: ADDR,
      abi: DEPOSIT_POLICY_ABI,
      functionName: "getDepositLimit",
      args: [ADDR],
      expected: 500n,
      format: "assetWei",
      pick: (raw) => (raw as { capacity: bigint }).capacity,
    };
    const client = mockClient([{ status: "failure", error: new Error("execution reverted") }]);
    const results = await runParity({ client, blockNumber: 1n, specs: [spec] });
    expect(results[0]!.severity).toBe("error");
    expect(results[0]!.note).toContain("execution reverted");
  });

  it("respects skipIf and never calls the RPC for those entries", async () => {
    const spec: GetterSpec = {
      group: "DepositPolicy",
      key: "DepositPolicy.skip",
      address: ADDR,
      abi: DEPOSIT_POLICY_ABI,
      functionName: "getDepositLimit",
      args: [ADDR],
      expected: 0n,
      format: "assetWei",
      skipIf: { reason: "asset not yet registered" },
    };
    let called = false;
    const client: any = { multicall: async () => ((called = true), []) };
    const results = await runParity({ client, blockNumber: 1n, specs: [spec] });
    expect(called).toBe(false);
    expect(results[0]!.severity).toBe("skipped");
  });
});
