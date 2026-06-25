import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { humanise } from "../lib/format.js";

describe("humanise", () => {
  it("formats bps with percent suffix", () => {
    assert.equal(humanise(625n, "bps"), "625 bps (6.25%)");
    assert.equal(humanise(100n, "bps"), "100 bps (1%)");
  });

  it("formats seconds with readable suffix", () => {
    assert.equal(humanise(1800n, "seconds"), "1800s (30m)");
    assert.equal(humanise(86_400n, "seconds"), "86400s (1d)");
  });

  it("formats bool", () => {
    assert.equal(humanise(true, "bool"), "true");
    assert.equal(humanise(false, "bool"), "false");
  });

  it("abbreviates addresses", () => {
    assert.equal(humanise("0x1cc0842d45c50b1c36c103b3c0586a6f81062dab", "address"), "0x1cc0…2dab");
  });

  it("formats assetWei with asset symbol when key implies one", () => {
    // 500 GHO (18 decimals)
    const v = 500n * 10n ** 18n;
    const out = humanise(v, "assetWei", "DepositPolicy.gho.capacity");
    assert.ok(out.includes("500"));
    assert.ok(out.includes("GHO"));
  });

  it("falls back to raw on unknown format", () => {
    assert.equal(humanise(42n), "42");
    assert.equal(humanise(undefined), "—");
  });
});
