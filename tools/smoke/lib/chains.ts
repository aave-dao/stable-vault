// Chain definitions for the smoke harness. We support Arbitrum + Ethereum L1
// (and their sepolia testnets) per the Primer's accounting/earning split.

import { arbitrum, arbitrumSepolia, mainnet, sepolia, type Chain } from "viem/chains";

export const CHAINS_BY_ID = new Map<number, Chain>([
  [1, mainnet],
  [42161, arbitrum],
  [11_155_111, sepolia],
  [421_614, arbitrumSepolia],
]);

export function chainById(chainId: number): Chain | undefined {
  return CHAINS_BY_ID.get(chainId);
}
