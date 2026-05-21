/**
 * Hand-curated catalogue of deployment parameters. Each entry pairs a knob in `deployment-config.*.jsonc`
 * (or a Solidity constant) with the on-chain setter that mutates it, the unit, the relevant chain context,
 * and the immutable floors / ceilings that apply.
 *
 * The pipeline expands per-asset / per-chain templates against the configs to produce one `ParameterJson`
 * per row. `setterKeys` must match `Roles.key` values in the same artifact — `build-roles-json.ts` resolves
 * them after roles are built.
 *
 * Categories are loose groupings that mirror the Risk Parameters One Pager sections, so the Notion DB can be
 * sliced into the same layout via filtered views.
 */
import type { ChainContext } from "./types.js";

export type AssetKey = "gho" | "usdc" | "usdt";

export const ASSET_DECIMALS: Record<AssetKey, number> = {
  gho: 18,
  usdc: 6,
  usdt: 6,
};

export const ASSET_SYMBOL: Record<AssetKey, string> = {
  gho: "GHO",
  usdc: "USDC",
  usdt: "USDT",
};

export type ValueFormat =
  | "raw"
  | "bps"
  | "seconds"
  | "ray" // RAY-encoded balance/price: renders as $X or 0.YYY
  | "rayPerSec" // RAY-encoded rate: renders as $X/day
  | "assetWei" // wei in asset-native decimals: renders as "X SYMBOL"
  | "assetWeiPerSec" // wei in asset-native decimals per second: renders as "X SYMBOL/day"
  | "bool"
  | "address"
  | "uint";

export type ValueSpec =
  | { type: "scalar"; path: string; format: ValueFormat }
  | { type: "perAsset"; pathTemplate: string; assets: AssetKey[]; format: ValueFormat };

export interface ParameterSpec {
  key: string;
  contract: string;
  category:
    | "Yield economics"
    | "Withdrawal fees + signers"
    | "Rate-limit buckets — Deposit"
    | "Rate-limit buckets — Bridging"
    | "Rate-limit buckets — Redemption"
    | "Oracle"
    | "Slippage coverage"
    | "Strategy onboarding"
    | "Cross-chain topology"
    | "Token metadata";
  chainContext: ChainContext;
  /** Role keys (from RolesConfig) that mutate this parameter. Empty for immutables / deploy-only constants. */
  setterKeys: string[];
  unit: string;
  onChainLimits: string;
  value: ValueSpec;
}

export const PARAMETER_SPECS: ParameterSpec[] = [
  // -------- Yield economics (AC) --------
  {
    key: "StableVault.defaultSubVaultPerSecondRate",
    contract: "StableVault",
    category: "Yield economics",
    chainContext: "AC",
    setterKeys: ["StableVault.setSubVaultRate", "StableVault.setDefaultSubVault"],
    unit: "RAY/sec",
    onChainLimits: "≤ MAX_VALID_PER_SECOND_RATE (≈ 20% APY)",
    value: { type: "scalar", path: "accountingChain.defaultSubVaultPerSecondRate", format: "ray" },
  },
  {
    key: "StableVault.defaultMaxPerSecondRate",
    contract: "StableVault",
    category: "Yield economics",
    chainContext: "AC",
    setterKeys: [],
    unit: "RAY/sec",
    onChainLimits: "Constructor-set ceiling; immutable after deploy",
    value: { type: "scalar", path: "accountingChain.defaultMaxPerSecondRate", format: "ray" },
  },
  {
    key: "StableVault.defaultMaxActiveSubVaults",
    contract: "StableVault",
    category: "Yield economics",
    chainContext: "AC",
    setterKeys: [],
    unit: "count",
    onChainLimits: "Hard cap; immutable",
    value: { type: "scalar", path: "accountingChain.defaultMaxActiveSubVaults", format: "uint" },
  },

  // -------- Withdrawal fees + signers (top-level, applies to AC + EC instances of the policy) --------
  {
    key: "WithdrawalExecutionPolicy.defaultFeeBps",
    contract: "WithdrawalExecutionPolicy",
    category: "Withdrawal fees + signers",
    chainContext: "AC+EC",
    setterKeys: ["WithdrawalExecutionPolicy.setDefaultFeeBps"],
    unit: "bps",
    onChainLimits: "≤ FEE_CAP_BPS = 1000 (10%)",
    value: { type: "scalar", path: "withdrawalExecutionPolicy.defaultFeeBps", format: "bps" },
  },
  {
    key: "WithdrawalExecutionPolicy.signer",
    contract: "WithdrawalExecutionPolicy",
    category: "Withdrawal fees + signers",
    chainContext: "AC+EC",
    setterKeys: ["WithdrawalExecutionPolicy.addSigner", "WithdrawalExecutionPolicy.removeSigner"],
    unit: "address",
    onChainLimits: "",
    value: { type: "scalar", path: "withdrawalExecutionPolicy.signer", format: "address" },
  },

  // -------- Rate-limit buckets — Deposit (AC) --------
  {
    key: "DepositPolicy.bucket.capacity",
    contract: "DepositPolicy",
    category: "Rate-limit buckets — Deposit",
    chainContext: "AC",
    setterKeys: ["DepositPolicy.raiseDepositCapacity", "DepositPolicy.lowerDepositCapacity"],
    unit: "asset-native dec, per asset",
    onChainLimits: "",
    value: {
      type: "perAsset",
      pathTemplate: "accountingChain.depositPolicy.perAssetLimits.{asset}.capacity",
      assets: ["gho", "usdc", "usdt"],
      format: "assetWei",
    },
  },
  {
    key: "DepositPolicy.bucket.refillRate",
    contract: "DepositPolicy",
    category: "Rate-limit buckets — Deposit",
    chainContext: "AC",
    setterKeys: ["DepositPolicy.raiseDepositRefillRate", "DepositPolicy.lowerDepositRefillRate"],
    unit: "asset-native dec / sec, per asset",
    onChainLimits: "",
    value: {
      type: "perAsset",
      pathTemplate: "accountingChain.depositPolicy.perAssetLimits.{asset}.refillRate",
      assets: ["gho", "usdc", "usdt"],
      format: "assetWeiPerSec",
    },
  },

  // -------- Rate-limit buckets — Bridging (AC + EC, separate rows so divergent values are visible) --------
  {
    key: "FundsBridgingPolicy.bucket.capacity (AC)",
    contract: "FundsBridgingPolicy",
    category: "Rate-limit buckets — Bridging",
    chainContext: "AC",
    setterKeys: ["FundsBridgingPolicy.raiseBridgingCapacity", "FundsBridgingPolicy.lowerBridgingCapacity"],
    unit: "asset-native dec, per asset",
    onChainLimits: "",
    value: {
      type: "perAsset",
      pathTemplate: "accountingChain.fundsBridgingPolicy.perAssetLimits.{asset}.capacity",
      assets: ["gho", "usdc", "usdt"],
      format: "assetWei",
    },
  },
  {
    key: "FundsBridgingPolicy.bucket.refillRate (AC)",
    contract: "FundsBridgingPolicy",
    category: "Rate-limit buckets — Bridging",
    chainContext: "AC",
    setterKeys: ["FundsBridgingPolicy.raiseBridgingRefillRate", "FundsBridgingPolicy.lowerBridgingRefillRate"],
    unit: "asset-native dec / sec, per asset",
    onChainLimits: "",
    value: {
      type: "perAsset",
      pathTemplate: "accountingChain.fundsBridgingPolicy.perAssetLimits.{asset}.refillRate",
      assets: ["gho", "usdc", "usdt"],
      format: "assetWeiPerSec",
    },
  },
  {
    key: "FundsBridgingPolicy.bucket.capacity (EC)",
    contract: "FundsBridgingPolicy",
    category: "Rate-limit buckets — Bridging",
    chainContext: "EC",
    setterKeys: ["FundsBridgingPolicy.raiseBridgingCapacity", "FundsBridgingPolicy.lowerBridgingCapacity"],
    unit: "asset-native dec, per asset",
    onChainLimits: "",
    value: {
      type: "perAsset",
      pathTemplate: "earningChain.fundsBridgingPolicy.perAssetLimits.{asset}.capacity",
      assets: ["gho", "usdc", "usdt"],
      format: "assetWei",
    },
  },
  {
    key: "FundsBridgingPolicy.bucket.refillRate (EC)",
    contract: "FundsBridgingPolicy",
    category: "Rate-limit buckets — Bridging",
    chainContext: "EC",
    setterKeys: ["FundsBridgingPolicy.raiseBridgingRefillRate", "FundsBridgingPolicy.lowerBridgingRefillRate"],
    unit: "asset-native dec / sec, per asset",
    onChainLimits: "",
    value: {
      type: "perAsset",
      pathTemplate: "earningChain.fundsBridgingPolicy.perAssetLimits.{asset}.refillRate",
      assets: ["gho", "usdc", "usdt"],
      format: "assetWeiPerSec",
    },
  },

  // -------- Rate-limit buckets — Redemption (AC + EC) --------
  {
    key: "WithdrawalExecutionPolicy.redemptionBucket.capacity (AC)",
    contract: "WithdrawalExecutionPolicy",
    category: "Rate-limit buckets — Redemption",
    chainContext: "AC",
    setterKeys: [
      "WithdrawalExecutionPolicy.raiseRedemptionCapacity",
      "WithdrawalExecutionPolicy.lowerRedemptionCapacity",
    ],
    unit: "RAY",
    onChainLimits: "≥ MIN_REDEMPTION_CAPACITY (immutable per impl)",
    value: {
      type: "scalar",
      path: "accountingChain.withdrawalExecutionPolicy.redemptionLimit.capacityRay",
      format: "ray",
    },
  },
  {
    key: "WithdrawalExecutionPolicy.redemptionBucket.refillRate (AC)",
    contract: "WithdrawalExecutionPolicy",
    category: "Rate-limit buckets — Redemption",
    chainContext: "AC",
    setterKeys: [
      "WithdrawalExecutionPolicy.raiseRedemptionRefillRate",
      "WithdrawalExecutionPolicy.lowerRedemptionRefillRate",
    ],
    unit: "RAY/sec",
    onChainLimits: "≥ MIN_REDEMPTION_REFILL_RATE (immutable per impl)",
    value: {
      type: "scalar",
      path: "accountingChain.withdrawalExecutionPolicy.redemptionLimit.refillRateRay",
      format: "rayPerSec",
    },
  },
  {
    key: "WithdrawalExecutionPolicy.minRedemptionCapacityRay (AC)",
    contract: "WithdrawalExecutionPolicy",
    category: "Rate-limit buckets — Redemption",
    chainContext: "AC",
    setterKeys: [],
    unit: "RAY",
    onChainLimits: "Immutable floor; bakes into impl bytecode",
    value: {
      type: "scalar",
      path: "accountingChain.withdrawalExecutionPolicy.minRedemptionCapacityRay",
      format: "ray",
    },
  },
  {
    key: "WithdrawalExecutionPolicy.minRedemptionRefillRateRay (AC)",
    contract: "WithdrawalExecutionPolicy",
    category: "Rate-limit buckets — Redemption",
    chainContext: "AC",
    setterKeys: [],
    unit: "RAY/sec",
    onChainLimits: "Immutable floor; bakes into impl bytecode",
    value: {
      type: "scalar",
      path: "accountingChain.withdrawalExecutionPolicy.minRedemptionRefillRateRay",
      format: "rayPerSec",
    },
  },
  {
    key: "WithdrawalExecutionPolicy.redemptionBucket.capacity (EC)",
    contract: "WithdrawalExecutionPolicy",
    category: "Rate-limit buckets — Redemption",
    chainContext: "EC",
    setterKeys: [
      "WithdrawalExecutionPolicy.raiseRedemptionCapacity",
      "WithdrawalExecutionPolicy.lowerRedemptionCapacity",
    ],
    unit: "RAY",
    onChainLimits: "≥ MIN_REDEMPTION_CAPACITY (immutable per impl)",
    value: {
      type: "scalar",
      path: "earningChain.withdrawalExecutionPolicy.redemptionLimit.capacityRay",
      format: "ray",
    },
  },
  {
    key: "WithdrawalExecutionPolicy.redemptionBucket.refillRate (EC)",
    contract: "WithdrawalExecutionPolicy",
    category: "Rate-limit buckets — Redemption",
    chainContext: "EC",
    setterKeys: [
      "WithdrawalExecutionPolicy.raiseRedemptionRefillRate",
      "WithdrawalExecutionPolicy.lowerRedemptionRefillRate",
    ],
    unit: "RAY/sec",
    onChainLimits: "≥ MIN_REDEMPTION_REFILL_RATE (immutable per impl)",
    value: {
      type: "scalar",
      path: "earningChain.withdrawalExecutionPolicy.redemptionLimit.refillRateRay",
      format: "rayPerSec",
    },
  },
  {
    key: "WithdrawalExecutionPolicy.minRedemptionCapacityRay (EC)",
    contract: "WithdrawalExecutionPolicy",
    category: "Rate-limit buckets — Redemption",
    chainContext: "EC",
    setterKeys: [],
    unit: "RAY",
    onChainLimits: "Immutable floor; bakes into impl bytecode",
    value: {
      type: "scalar",
      path: "earningChain.withdrawalExecutionPolicy.minRedemptionCapacityRay",
      format: "ray",
    },
  },
  {
    key: "WithdrawalExecutionPolicy.minRedemptionRefillRateRay (EC)",
    contract: "WithdrawalExecutionPolicy",
    category: "Rate-limit buckets — Redemption",
    chainContext: "EC",
    setterKeys: [],
    unit: "RAY/sec",
    onChainLimits: "Immutable floor; bakes into impl bytecode",
    value: {
      type: "scalar",
      path: "earningChain.withdrawalExecutionPolicy.minRedemptionRefillRateRay",
      format: "rayPerSec",
    },
  },

  // -------- Oracle (AC + EC) --------
  {
    key: "PriceOracle.chainlinkHeartbeat",
    contract: "PriceOracle",
    category: "Oracle",
    chainContext: "AC+EC",
    setterKeys: ["PriceOracle.setOracleAdapterForAsset"],
    unit: "seconds (per adapter, constructor)",
    onChainLimits: "+ HEARTBEAT_BUFFER_SECONDS = 90",
    value: { type: "scalar", path: "chainlinkPriceOracleHeartbeat", format: "seconds" },
  },
  {
    key: "ChainBalanceOracle.chainlinkHeartbeat",
    contract: "ChainBalanceOracle",
    category: "Oracle",
    chainContext: "AC",
    setterKeys: ["ChainBalanceOracle.setChainBalanceOracleAdapter"],
    unit: "seconds (per adapter, constructor)",
    onChainLimits: "+ PUBLISH_BUFFER_SECONDS = 90",
    value: { type: "scalar", path: "chainlinkChainBalanceOracleHeartbeat", format: "seconds" },
  },
  {
    key: "PriceOracle.minValidPriceRay",
    contract: "PriceOracle",
    category: "Oracle",
    chainContext: "AC+EC",
    setterKeys: [],
    unit: "RAY",
    onChainLimits: "Immutable on impl; floors validatePrice() reverts",
    value: { type: "scalar", path: "priceOracleMinValidPriceRay", format: "ray" },
  },

  // -------- Slippage coverage (AC) --------
  {
    key: "SlippageCoverageVault.maxSlippageBps",
    contract: "SlippageCoverageVault",
    category: "Slippage coverage",
    chainContext: "AC",
    setterKeys: ["SlippageCoverageVault.setMaxSlippageBps"],
    unit: "bps",
    onChainLimits: "< 10_000 bps",
    value: { type: "scalar", path: "slippageCoverageVault.maxSlippageBps", format: "bps" },
  },
  {
    key: "SlippageCoverageVault.overrideMaxSlippageBps",
    contract: "SlippageCoverageVault",
    category: "Slippage coverage",
    chainContext: "AC",
    setterKeys: ["SlippageCoverageVault.setOverrideMaxSlippageBps"],
    unit: "bps",
    onChainLimits: "",
    value: { type: "scalar", path: "slippageCoverageVault.overrideMaxSlippageBps", format: "bps" },
  },
  {
    key: "SlippageCoverageVault.initialOverrideMode",
    contract: "SlippageCoverageVault",
    category: "Slippage coverage",
    chainContext: "AC",
    setterKeys: ["SlippageCoverageVault.enableOverrideMode", "SlippageCoverageVault.disableOverrideMode"],
    unit: "bool (seed via constructor)",
    onChainLimits: "",
    value: { type: "scalar", path: "slippageCoverageVault.initialOverrideMode", format: "bool" },
  },
  {
    key: "SlippageCoverageVault.pullCapPerTx",
    contract: "SlippageCoverageVault",
    category: "Slippage coverage",
    chainContext: "AC",
    setterKeys: ["SlippageCoverageVault.raisePullCapPerTx", "SlippageCoverageVault.lowerPullCapPerTx"],
    unit: "asset-native dec, per asset",
    onChainLimits: "",
    value: {
      type: "perAsset",
      pathTemplate: "slippageCoverageVault.perAssetCaps.{asset}.pullCapPerTx",
      assets: ["gho", "usdc", "usdt"],
      format: "assetWei",
    },
  },
  {
    key: "SlippageCoverageVault.windowCap",
    contract: "SlippageCoverageVault",
    category: "Slippage coverage",
    chainContext: "AC",
    setterKeys: ["SlippageCoverageVault.raiseWindowCap", "SlippageCoverageVault.lowerWindowCap"],
    unit: "asset-native dec, per asset",
    onChainLimits: "",
    value: {
      type: "perAsset",
      pathTemplate: "slippageCoverageVault.perAssetCaps.{asset}.windowCap",
      assets: ["gho", "usdc", "usdt"],
      format: "assetWei",
    },
  },
  {
    key: "SlippageCoverageVault.windowSeconds",
    contract: "SlippageCoverageVault",
    category: "Slippage coverage",
    chainContext: "AC",
    setterKeys: ["SlippageCoverageVault.raiseWindowSeconds", "SlippageCoverageVault.lowerWindowSeconds"],
    unit: "seconds, per asset",
    onChainLimits: "> 0",
    value: {
      type: "perAsset",
      pathTemplate: "slippageCoverageVault.perAssetCaps.{asset}.windowSeconds",
      assets: ["gho", "usdc", "usdt"],
      format: "seconds",
    },
  },

  // -------- Strategy onboarding (AC) --------
  {
    key: "Allocator.maxStrategiesPerAsset",
    contract: "Allocator",
    category: "Strategy onboarding",
    chainContext: "AC",
    setterKeys: [],
    unit: "count",
    onChainLimits: "Immutable; caps strategy iteration in Allocator.withdraw",
    value: { type: "scalar", path: "maxStrategiesPerAsset", format: "uint" },
  },

  // -------- Cross-chain topology --------
  {
    key: "FundsHandler.earningChainId",
    contract: "FundsHandler",
    category: "Cross-chain topology",
    chainContext: "AC",
    setterKeys: ["FundsHandler.addEarningChain", "FundsHandler.removeEarningChain"],
    unit: "chainId",
    onChainLimits: "",
    value: { type: "scalar", path: "earningChain.chainId", format: "uint" },
  },
  {
    key: "CcipBridgeAdapter.earningChainSelector",
    contract: "CcipBridgeAdapter",
    category: "Cross-chain topology",
    chainContext: "AC",
    setterKeys: ["CcipBridgeAdapter.setChainSelector"],
    unit: "uint64 (CCIP)",
    onChainLimits: "",
    value: { type: "scalar", path: "earningChain.ccipSelector", format: "raw" },
  },
  {
    key: "CcipBridgeAdapter.accountingChainSelector",
    contract: "CcipBridgeAdapter",
    category: "Cross-chain topology",
    chainContext: "EC",
    setterKeys: ["CcipBridgeAdapter.setChainSelector"],
    unit: "uint64 (CCIP)",
    onChainLimits: "",
    value: { type: "scalar", path: "accountingChain.ccipSelector", format: "raw" },
  },
  {
    key: "EarningChainGateway.minBurnIouTokenGasLimit",
    contract: "EarningChainGateway",
    category: "Cross-chain topology",
    chainContext: "EC",
    setterKeys: [],
    unit: "gas",
    onChainLimits: "Constant in source (MIN_BURN_IOU_TOKEN_GAS_LIMIT)",
    value: { type: "scalar", path: "earningChain.minBurnIouTokenGasLimit", format: "uint" },
  },

  // -------- Token metadata (deploy-only) --------
  {
    key: "StableVault.iouTokenName",
    contract: "StableVault",
    category: "Token metadata",
    chainContext: "AC",
    setterKeys: [],
    unit: "string",
    onChainLimits: "Set in constructor; immutable",
    value: { type: "scalar", path: "iouTokenName", format: "raw" },
  },
  {
    key: "StableVault.iouTokenSymbol",
    contract: "StableVault",
    category: "Token metadata",
    chainContext: "AC",
    setterKeys: [],
    unit: "string",
    onChainLimits: "Set in constructor; immutable",
    value: { type: "scalar", path: "iouTokenSymbol", format: "raw" },
  },
  {
    key: "StableVault.assetTokenName",
    contract: "StableVault",
    category: "Token metadata",
    chainContext: "AC",
    setterKeys: [],
    unit: "string",
    onChainLimits: "Set in constructor; immutable",
    value: { type: "scalar", path: "accountingChain.stableVaultName", format: "raw" },
  },
  {
    key: "StableVault.assetTokenSymbol",
    contract: "StableVault",
    category: "Token metadata",
    chainContext: "AC",
    setterKeys: [],
    unit: "string",
    onChainLimits: "Set in constructor; immutable",
    value: { type: "scalar", path: "accountingChain.stableVaultSymbol", format: "raw" },
  },
];

export const PARAMETER_CATEGORIES = [
  "Yield economics",
  "Withdrawal fees + signers",
  "Rate-limit buckets — Deposit",
  "Rate-limit buckets — Bridging",
  "Rate-limit buckets — Redemption",
  "Oracle",
  "Slippage coverage",
  "Strategy onboarding",
  "Cross-chain topology",
  "Token metadata",
] as const;
