// Port of script/libraries/Create3AddressLib.sol. Computes the CREATE3 deployment
// address for a given namespaced salt seed and deployer, matching the on-chain
// algorithm byte-for-byte so smoke can re-derive every artefact-recorded address
// from JSONC config alone.

import { getAddress, keccak256, toHex, type Address, type Hex } from "viem";

export const CREATEX_ADDRESS = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed" as const;

// Matches Create3AddressLib.DEPLOYER_ADDRESS_ZEROING_MASK + CROSS_CHAIN_PROTECTION_MASK.
const DEPLOYER_ADDRESS_ZEROING_MASK = 0x0000000000000000000000000000000000000000ffffffffffffffffffffffffn;
const CROSS_CHAIN_PROTECTION_MASK = 0xffffffffffffffffffffffffffffffffffffffff00ffffffffffffffffffffffn;

// keccak256 of the createx proxy's runtime bytecode; baked into the factory's address derivation.
const PROXY_INITCODE_HASH = "0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f" as const;

const padHex32 = (n: bigint): Hex => `0x${n.toString(16).padStart(64, "0")}` as Hex;

/**
 * Compute the deployer-guarded, cross-chain-protected salt the deploy script
 * passes to createx. Mirrors Create3AddressLib.computeCreate3Salt.
 */
export function computeCreate3Salt(seed: string, deployer: Address): Hex {
  const seedHash = BigInt(keccak256(toHex(seed)));
  const masked = seedHash & DEPLOYER_ADDRESS_ZEROING_MASK & CROSS_CHAIN_PROTECTION_MASK;
  const deployerBig = BigInt(deployer);
  return padHex32(masked | (deployerBig << 96n));
}

/**
 * Hash the salt with the deployer to produce the value createx ultimately uses.
 * Mirrors the private _computeCreate3GuardedSalt helper.
 */
export function computeCreate3GuardedSalt(seed: string, deployer: Address): Hex {
  const salt = computeCreate3Salt(seed, deployer);
  const deployerPadded = padHex32(BigInt(deployer));
  return keccak256(`${deployerPadded}${salt.slice(2)}` as Hex);
}

/**
 * Compute the final CREATE3 address. Two-step: derive the createx proxy address
 * via standard CREATE2, then derive the CREATE address from that proxy at nonce 1.
 */
export function computeCreate3Address(seed: string, deployer: Address): Address {
  const guardedSalt = computeCreate3GuardedSalt(seed, deployer);
  const proxyHashInput =
    `0xff${CREATEX_ADDRESS.slice(2).toLowerCase()}${guardedSalt.slice(2)}${PROXY_INITCODE_HASH.slice(2)}` as Hex;
  const proxyHash = keccak256(proxyHashInput);
  const proxy = `0x${proxyHash.slice(-40)}` as Address;
  // RLP-encoded [proxy, 1] for CREATE address derivation: 0xd6 0x94 <20 bytes> 0x01
  const finalInput = `0xd694${proxy.slice(2).toLowerCase()}01` as Hex;
  const finalHash = keccak256(finalInput);
  return getAddress(`0x${finalHash.slice(-40)}`);
}
