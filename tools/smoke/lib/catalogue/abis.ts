// Hand-curated ABI fragments for the getters smoke calls. Kept small and
// inline-typed so viem can infer return shapes; full ABIs from out/ are not
// imported because we don't need write functions, events, or errors.

export const DEPOSIT_POLICY_ABI = [
  {
    type: "function",
    name: "getDepositLimit",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "capacity", type: "uint128" },
          { name: "refillRate", type: "uint128" },
          { name: "consumed", type: "uint128" },
          { name: "lastRefillTimestamp", type: "uint64" },
        ],
      },
    ],
  },
] as const;

export const FUNDS_BRIDGING_POLICY_ABI = [
  {
    type: "function",
    name: "getBridgingLimit",
    stateMutability: "view",
    inputs: [
      { name: "asset", type: "address" },
      { name: "destChainId", type: "uint256" },
      { name: "bridgeAdapter", type: "address" },
    ],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "capacity", type: "uint128" },
          { name: "refillRate", type: "uint128" },
          { name: "consumed", type: "uint128" },
          { name: "lastRefillTimestamp", type: "uint64" },
        ],
      },
    ],
  },
] as const;

export const SLIPPAGE_COVERAGE_VAULT_ABI = [
  {
    type: "function",
    name: "getMaxSlippageBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "getOverrideMaxSlippageBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "getOverrideMode",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "getPullCapPerTx",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "getWindow",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "cap", type: "uint256" },
          { name: "windowSeconds", type: "uint32" },
          { name: "consumed", type: "uint256" },
          { name: "windowStart", type: "uint64" },
        ],
      },
    ],
  },
] as const;
