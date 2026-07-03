// Unit tests for the bytecode matcher's pure helpers (mask immutable ranges + strip CBOR
// metadata). The full matchDeployedBytecode() reads on-disk Foundry artefacts and is exercised
// end-to-end by the harness against a real build; here we pin the byte-surgery logic.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { maskRanges, stripCborMetadata, strip0x } from "../lib/bytecode.js";

describe("maskRanges", () => {
  it("zeros exactly the named byte ranges (offsets in bytes)", () => {
    // bytes: aa bb cc dd ee ff - mask start=1 length=2 -> bytes 1,2
    assert.equal(maskRanges("aabbccddeeff", { x: [{ start: 1, length: 2 }] }), "aa0000ddeeff");
  });

  it("handles multiple refs and multiple ranges per ref", () => {
    assert.equal(
      maskRanges("aabbccddeeff", { a: [{ start: 0, length: 1 }], b: [{ start: 5, length: 1 }] }),
      "00bbccddee00",
    );
  });

  it("is a no-op with no refs", () => {
    assert.equal(maskRanges("aabbccdd", {}), "aabbccdd");
  });
});

describe("stripCborMetadata", () => {
  it("strips a plausible trailing CBOR blob (length in the final 2 bytes)", () => {
    // logic "dead" + 11 metadata bytes + 2-byte length 0x000b
    const hex = "dead" + "aa".repeat(11) + "000b";
    assert.equal(stripCborMetadata(hex), "dead");
  });

  it("returns null when the encoded length is implausible", () => {
    assert.equal(stripCborMetadata("dead" + "aa".repeat(11) + "ffff"), null); // mlen 65535 > hex
    assert.equal(stripCborMetadata("0001"), null); // mlen 1 < 10 floor
  });
});

describe("strip0x", () => {
  it("removes a leading 0x and leaves bare hex untouched", () => {
    assert.equal(strip0x("0xabcd"), "abcd");
    assert.equal(strip0x("abcd"), "abcd");
  });
});

describe("immutable-masked equivalence (the core tier)", () => {
  it("two builds that differ only at an immutable site mask to the same logic", () => {
    const refs = { id: [{ start: 2, length: 2 }] };
    const artifact = "aabb0000ccdd"; // solc zeros immutable sites
    const onchain = "aabb1234ccdd"; // deploy filled the immutable
    assert.notEqual(artifact, onchain);
    assert.equal(maskRanges(artifact, refs), maskRanges(onchain, refs));
  });
});
