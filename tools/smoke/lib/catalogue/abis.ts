// Hand-curated ABI fragments for every getter smoke calls. Kept small and
// `as const` so viem can infer return shapes. Full ABIs from `out/` are not
// imported — we don't need write functions, events, or errors.

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

export const STABLE_VAULT_ABI = [
  {
    type: "function",
    name: "getTreasury",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "getDefaultSubVault",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "perSecondRate", type: "uint256" },
          { name: "id", type: "uint256" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "getMaxValidPerSecondRate",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "name",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
] as const;

export const IOU_TOKEN_ABI = [
  {
    type: "function",
    name: "name",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
] as const;

export const WITHDRAWAL_EXECUTION_POLICY_ABI = [
  {
    type: "function",
    name: "getDefaultFeeBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "isSigner",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "getRedemptionBucket",
    stateMutability: "view",
    inputs: [],
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
  {
    type: "function",
    name: "getMinRedemptionCapacity",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "getMinRedemptionRefillRate",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export const ASSET_REGISTRY_ABI = [
  {
    type: "function",
    name: "isAssetRegistered",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "isAssetTrusted",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "getAssetConfig",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "depositFromUserAllowed", type: "bool" },
          { name: "depositIntoAllocatorAllowed", type: "bool" },
          { name: "swapInputTokenAllowed", type: "bool" },
          { name: "swapOutputTokenAllowed", type: "bool" },
        ],
      },
    ],
  },
] as const;

export const ALLOCATOR_ABI = [
  {
    type: "function",
    name: "getStrategiesForAsset",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "address[]" }],
  },
  {
    type: "function",
    name: "isStrategySupportedForAsset",
    stateMutability: "view",
    inputs: [
      { name: "asset", type: "address" },
      { name: "strategy", type: "address" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "isStrategyTrusted",
    stateMutability: "view",
    inputs: [{ name: "strategy", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "getStrategyConfig",
    stateMutability: "view",
    inputs: [{ name: "strategy", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "asset", type: "address" },
          { name: "isRegistered", type: "bool" },
          { name: "depositAllowed", type: "bool" },
          { name: "isTrusted", type: "bool" },
        ],
      },
    ],
  },
] as const;

export const PRICE_ORACLE_ABI = [
  {
    type: "function",
    name: "getOracleAdapterForAsset",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "getPrice",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export const CHAIN_BALANCE_ORACLE_ABI = [
  {
    type: "function",
    name: "getChainBalanceOracleAdapter",
    stateMutability: "view",
    inputs: [{ name: "chainId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "getChainBalance",
    stateMutability: "view",
    inputs: [{ name: "chainId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "balanceRay", type: "uint256" },
          { name: "lastUpdateTimestamp", type: "uint64" },
          { name: "sourceChainTimestamp", type: "uint64" },
          { name: "sourceChainBlockNumber", type: "uint64" },
          { name: "isStale", type: "bool" },
        ],
      },
    ],
  },
] as const;

export const BASE_CHAIN_GATEWAY_ABI = [
  {
    type: "function",
    name: "isBridgeAdapterSupported",
    stateMutability: "view",
    inputs: [
      { name: "asset", type: "address" },
      { name: "chainId", type: "uint256" },
      { name: "bridgeAdapter", type: "address" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

export const CCIP_ROUTER_ABI = [
  {
    type: "function",
    name: "isChainSupported",
    stateMutability: "view",
    inputs: [{ name: "destChainSelector", type: "uint64" }],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

export const CHAINLINK_SEQUENCER_FEED_ABI = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

export const ACCESS_MANAGER_ABI = [
  {
    type: "function",
    name: "getRoleGrantDelay",
    stateMutability: "view",
    inputs: [{ name: "roleId", type: "uint64" }],
    outputs: [{ name: "", type: "uint32" }],
  },
  {
    type: "function",
    name: "hasRole",
    stateMutability: "view",
    inputs: [
      { name: "roleId", type: "uint64" },
      { name: "account", type: "address" },
    ],
    outputs: [
      { name: "isMember", type: "bool" },
      { name: "executionDelay", type: "uint32" },
    ],
  },
  {
    type: "function",
    name: "getTargetFunctionRole",
    stateMutability: "view",
    inputs: [
      { name: "target", type: "address" },
      { name: "selector", type: "bytes4" },
    ],
    outputs: [{ name: "", type: "uint64" }],
  },
] as const;
