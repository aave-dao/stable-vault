// Golden vector + structural tests for the CREATE3 derivation.
//
// The golden vector is pinned against the Solidity reference output rather than
// a deployment artefact address: the artefact is updated key-by-key by the deploy
// script, so a stale entry there is exactly the failure mode the harness catches,
// and would make a poor fixture.

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { getAddress } from "viem";

import { computeCreate3Address, computeCreate3Salt } from "../lib/create3.js";

const PREPROD_DEPLOYER = getAddress("0xdca997Dc3a41df1D51F5BBe2091064cdD796e359");

describe("computeCreate3Address", () => {
  // Golden vector cross-checked against the Solidity reference implementation
  // (script/libraries/Create3AddressLib.sol) for the preprod deployer.
  it("matches the Solidity reference for TransferHelper", () => {
    assert.equal(
      computeCreate3Address("aave.stable-vault.TransferHelper", PREPROD_DEPLOYER),
      getAddress("0x2f2C74890958f6C850d931E902e7bBb80750bA09"),
    );
  });

  it("produces a different address when the deployer changes", () => {
    const a = computeCreate3Address("aave.stable-vault.TransferHelper", PREPROD_DEPLOYER);
    const b = computeCreate3Address(
      "aave.stable-vault.TransferHelper",
      getAddress("0xBB700dA5CCC9Ec5605780Fc40695f1206B090303"),
    );
    assert.notEqual(a, b);
  });

  it("produces a different address when the seed changes", () => {
    const a = computeCreate3Address("aave.stable-vault.TransferHelper", PREPROD_DEPLOYER);
    const b = computeCreate3Address("aave.stable-vault.AccessManager", PREPROD_DEPLOYER);
    assert.notEqual(a, b);
  });
});

describe("computeCreate3Salt", () => {
  it("packs the deployer into the high 20 bytes of the salt", () => {
    const salt = computeCreate3Salt("aave.stable-vault.TransferHelper", PREPROD_DEPLOYER);
    // High 20 bytes (chars 2..42 of the hex string, since "0x" is 2 chars) should be the deployer.
    const highBytes = `0x${salt.slice(2, 2 + 40)}`;
    assert.equal(getAddress(highBytes), PREPROD_DEPLOYER);
  });
});
