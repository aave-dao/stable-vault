// Topology check: prove every artefact entry has bytecode at the expected
// CREATE3 address, the bytecode matches what we'd produce from the source,
// and transparent proxies point at the recorded implementation.
//
// Four layers per entry:
//   1. CREATE3 re-derivation (if saltSeed is non-empty) -> address matches artefact
//   2. code.length > 0 at the recorded address
//   3. Runtime bytecode logic match vs the current build (immutable- and metadata-tolerant);
//      skipped for proxy entries (their logic is the impl, checked via the ::Implementation
//      entry + the ERC-1967 slot below)
//   4. For transparent proxies: ERC-1967 impl slot matches the "<Name>::Implementation" entry

import { type Address, type Hex, type PublicClient } from "viem";

import { implEntry } from "../artefact.js";
import { computeCreate3Address } from "../create3.js";
import { matchDeployedBytecode } from "../bytecode.js";
import type { CheckResult, DeploymentArtefact } from "../types.js";

// keccak256("eip1967.proxy.implementation") - 1
const ERC1967_IMPL_SLOT: Hex = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

// Names that are intentionally absent from the artefact in some envs (e.g. a.DI
// adapter when registerOnGateway=false). Smoke skips them with a warning, not
// a failure.
const CONDITIONAL_ENTRIES: ReadonlySet<string> = new Set(["AdiAdapter"]);

interface TopologyArgs {
  artefact: DeploymentArtefact;
  deployer: Address;
  client: PublicClient;
  blockNumber: bigint;
  repoRoot: string;
}

export async function runTopology(args: TopologyArgs): Promise<CheckResult[]> {
  const { artefact, deployer, client, blockNumber, repoRoot } = args;
  const results: CheckResult[] = [];

  for (const [name, entry] of artefact.entries) {
    // NOTE: `<Name>::Implementation` entries are processed here too. The proxy's ERC-1967 slot only
    // proves the impl ADDRESS, not its code - so the impl's runtime bytecode must be matched on its
    // own (this is where the upgradeable contracts' logic actually lives). Impl entries have an empty
    // saltSeed (deployed via the CREATE3 factory's inner CREATE), so CREATE3 re-derivation is skipped
    // and the artefact address is accepted; they then get the code-presence + bytecode-match checks.

    // 1. CREATE3 re-derivation
    if (entry.saltSeed !== "") {
      const predicted = computeCreate3Address(entry.saltSeed, deployer);
      if (predicted.toLowerCase() !== entry.address.toLowerCase()) {
        results.push({
          group: "topology",
          key: `${name}.create3`,
          severity: "fail",
          expected: predicted,
          actual: entry.address,
          format: "address",
          note: "CREATE3 re-derivation does not match the artefact",
        });
        continue;
      }
      results.push({
        group: "topology",
        key: `${name}.address`,
        severity: "pass",
        expected: predicted,
        actual: entry.address,
        format: "address",
      });
    } else {
      results.push({
        group: "topology",
        key: `${name}.address`,
        severity: "pass",
        expected: entry.address,
        actual: entry.address,
        format: "address",
        note: "non-CREATE3 deploy (artefact accepted as ground truth)",
      });
    }

    // 2. code.length > 0
    const code = await client.getCode({ address: entry.address, blockNumber });
    if (!code || code === "0x") {
      results.push({
        group: "topology",
        key: `${name}.code`,
        severity: "fail",
        expected: ">0 bytes",
        actual: "0 bytes",
        note: "no code at predicted address (incomplete deploy)",
      });
      continue;
    }
    const codeSize = (code.length - 2) / 2;
    results.push({
      group: "topology",
      key: `${name}.code`,
      severity: "pass",
      expected: `>0 bytes`,
      actual: `${codeSize.toLocaleString()} bytes`,
    });

    // A "<Name>::Implementation" sibling means this entry is a proxy. Its runtime is OZ proxy
    // boilerplate, not the contract logic - so we don't byte-match the proxy itself; the logic is
    // verified on the ::Implementation entry (matched below) plus the ERC-1967 slot check.
    const recordedImpl = implEntry(artefact, name);

    // 3. Runtime bytecode logic match vs the current build (skips proxies).
    if (!recordedImpl) {
      const match = matchDeployedBytecode(name, code, repoRoot);
      if (match.kind === "no-artifact") {
        results.push({
          group: "topology",
          key: `${name}.bytecode`,
          severity: "warning",
          note: "could not resolve build artefact (run `forge build`)",
        });
      } else if (match.kind === "mismatch") {
        results.push({
          group: "topology",
          key: `${name}.bytecode`,
          severity: "fail",
          expected: "matches built artefact",
          actual: "differs",
          note: `runtime bytecode does not match the build - ${match.note}`,
        });
      } else {
        const note =
          match.kind === "exact"
            ? `exact match (${match.profile})`
            : match.kind === "immutables"
              ? `logic match (${match.profile}; ${match.count} immutable${match.count === 1 ? "" : "s"} set on-chain)`
              : `logic match (${match.profile}; compiler metadata differs)`;
        results.push({
          group: "topology",
          key: `${name}.bytecode`,
          severity: "pass",
          expected: "matches built artefact",
          actual: note,
        });
      }
    }

    // 4. ERC-1967 impl slot - only for contracts the deployment recorded an implementation for.
    // Driven by the artefact's "<Name>::Implementation" entry (ground truth) rather than a
    // hardcoded proxy set, so it self-maintains as topology changes (e.g. policies deployed
    // directly rather than behind a proxy won't false-fail with a zero impl slot).
    if (recordedImpl) {
      const slotRaw = await client.getStorageAt({
        address: entry.address,
        slot: ERC1967_IMPL_SLOT,
        blockNumber,
      });
      const onChainImpl = slotRaw ? (`0x${slotRaw.slice(-40)}` as Address) : null;
      if (!onChainImpl || onChainImpl === "0x0000000000000000000000000000000000000000") {
        results.push({
          group: "topology",
          key: `${name}.impl`,
          severity: "fail",
          expected: recordedImpl?.address ?? "(any)",
          actual: "0x0000…0000",
          note: "ERC-1967 implementation slot is zero",
        });
      } else if (recordedImpl && onChainImpl.toLowerCase() !== recordedImpl.address.toLowerCase()) {
        results.push({
          group: "topology",
          key: `${name}.impl`,
          severity: "fail",
          expected: recordedImpl.address,
          actual: onChainImpl,
          format: "address",
          note: "proxy points at unexpected implementation",
        });
      } else {
        results.push({
          group: "topology",
          key: `${name}.impl`,
          severity: "pass",
          expected: recordedImpl?.address ?? onChainImpl,
          actual: onChainImpl,
          format: "address",
        });
      }
    }
  }

  // Surface conditional entries that are absent so operators see them.
  for (const name of CONDITIONAL_ENTRIES) {
    if (!artefact.entries.has(name)) {
      results.push({
        group: "topology",
        key: `${name}.presence`,
        severity: "skipped",
        note: `${name} not deployed in this env (conditional contract)`,
      });
    }
  }

  return results;
}
