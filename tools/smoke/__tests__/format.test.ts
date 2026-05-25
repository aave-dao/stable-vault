import { describe, expect, it } from "vitest";
import { humanise } from "../lib/format.js";

describe("humanise", () => {
  it("formats bps with percent suffix", () => {
    expect(humanise(625n, "bps")).toBe("625 bps (6.25%)");
    expect(humanise(100n, "bps")).toBe("100 bps (1%)");
  });

  it("formats seconds with readable suffix", () => {
    expect(humanise(1800n, "seconds")).toBe("1800s (30m)");
    expect(humanise(86_400n, "seconds")).toBe("86400s (1d)");
  });

  it("formats bool", () => {
    expect(humanise(true, "bool")).toBe("true");
    expect(humanise(false, "bool")).toBe("false");
  });

  it("abbreviates addresses", () => {
    expect(humanise("0x1cc0842d45c50b1c36c103b3c0586a6f81062dab", "address")).toBe("0x1cc0…2dab");
  });

  it("formats assetWei with asset symbol when key implies one", () => {
    // 500 GHO (18 decimals)
    const v = 500n * 10n ** 18n;
    const out = humanise(v, "assetWei", "DepositPolicy.gho.capacity");
    expect(out).toContain("500");
    expect(out).toContain("GHO");
  });

  it("falls back to raw on unknown format", () => {
    expect(humanise(42n)).toBe("42");
    expect(humanise(undefined)).toBe("—");
  });
});
