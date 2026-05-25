// Golden vector + structural tests for the CREATE3 derivation.
//
// The single golden vector is TransferHelper from
// deployments/preprod/v1/accounting.json. Other artefact entries cannot be used
// as golden vectors because the artefact is updated key-by-key by the deploy
// script — older entries can lag behind a deployer change (this is precisely
// the "artefact stale" failure mode the smoke harness is designed to catch).

import { describe, expect, it } from "vitest";
import { getAddress } from "viem";

import { computeCreate3Address, computeCreate3Salt } from "../lib/create3.js";

const PREPROD_DEPLOYER = getAddress("0xdca997Dc3a41df1D51F5BBe2091064cdD796e359");

describe("computeCreate3Address", () => {
  // Golden vector cross-checked against the Solidity reference implementation
  // (script/libraries/Create3AddressLib.sol). When the preprod deployer config
  // changed, the deployment artefact carried stale entries from the prior deploy;
  // this vector pins the TS port against the canonical Solidity output instead.
  it("matches the Solidity reference for TransferHelper", () => {
    expect(computeCreate3Address("aave.stable-vault.TransferHelper", PREPROD_DEPLOYER)).toEqual(
      getAddress("0x2f2C74890958f6C850d931E902e7bBb80750bA09"),
    );
  });

  it("produces a different address when the deployer changes", () => {
    const a = computeCreate3Address("aave.stable-vault.TransferHelper", PREPROD_DEPLOYER);
    const b = computeCreate3Address(
      "aave.stable-vault.TransferHelper",
      getAddress("0xBB700dA5CCC9Ec5605780Fc40695f1206B090303"),
    );
    expect(a).not.toEqual(b);
  });

  it("produces a different address when the seed changes", () => {
    const a = computeCreate3Address("aave.stable-vault.TransferHelper", PREPROD_DEPLOYER);
    const b = computeCreate3Address("aave.stable-vault.AccessManager", PREPROD_DEPLOYER);
    expect(a).not.toEqual(b);
  });
});

describe("computeCreate3Salt", () => {
  it("packs the deployer into the high 20 bytes of the salt", () => {
    const salt = computeCreate3Salt("aave.stable-vault.TransferHelper", PREPROD_DEPLOYER);
    // High 20 bytes (chars 2..42 of the hex string, since "0x" is 2 chars) should be the deployer.
    const highBytes = `0x${salt.slice(2, 2 + 40)}`;
    expect(getAddress(highBytes)).toEqual(PREPROD_DEPLOYER);
  });
});
