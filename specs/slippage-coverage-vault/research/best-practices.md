# Best Practices — Push-Based Coverage Vault

## 1. Sliding-window data structure

**Recommendation: token bucket** (Chainlink CCIP `RateLimiter.sol` pattern), not "fixed-window counter with rollover on read".

The interview-notes propose a fixed-window counter. Its weakness — also flagged in your Risks — is the 2x burst at the boundary: drain `cap` at `windowStart + windowSeconds - 1`, drain `cap` again one second later.

Reference: Chainlink CCIP `RateLimiter.sol` (audited Code4rena 2023-05, 2024-11; reused by Aave GHO `UpgradeableLockReleaseTokenPool` / `UpgradeableBurnMintTokenPool`):

```solidity
struct TokenBucket {
  uint128 tokens;       // current available
  uint32  lastUpdated;
  bool    isEnabled;
  uint128 capacity;
  uint128 rate;         // tokens/sec refill
}
```

Hot path:
1. Read bucket (1 SLOAD warm).
2. If disabled, early return (no SSTORE).
3. Refill: `tokens = min(capacity, tokens + (now - lastUpdated) * rate)`.
4. Validate `requested <= tokens`.
5. Write `tokens -= requested; lastUpdated = uint32(now)` (1 SSTORE warm).

Beats fixed-window: same-block calls skip refill arithmetic; packed slot = single SSTORE.

If the v3 fixed-window stays, pack: `uint64 windowStart`, `uint64 windowSeconds`, `uint128 consumed`, `uint128 cap` — two slots. Memory copy → mutate → write once.

Edge cases:
- **First-pull default state**: zero `windowStart` → first call rolls over correctly (no constructor SSTORE per asset). Test: `test_pullCoverage_firstCallRollsOverFromZero`.
- **Setter mid-window**: decide explicitly whether `setWindowCap` resets `consumed` or applies new cap to remaining window. Document in NatSpec.
- **`block.timestamp`**: post-merge mainnet drift bounded by consensus; with 24h windows irrelevant. Don't use `block.number`.
- **Window zero**: reject `windowSeconds == 0` (DoS / divide-by-zero). Reject `< 1 hour` if defense-in-depth wanted.
- **Pause/upgrade**: `lastUpdated` stale on resume → bucket appears refilled. CCIP accepts this. To avoid, snapshot on unpause.

## 2. Push vs pull (allowance) trust model

Push-based is the right call. Precedents:
- **Aave GHO `UpgradeableLockReleaseTokenPool`** — pulled by Chainlink Router, never sets allowances on user-controlled contracts.
- **Optimism `L1StandardBridge`** — lock-and-mint with explicit `_initiateBridgeERC20` push.
- **Circle CCTP `TokenMessenger`** — `depositForBurn` pulls and burns; rate-limited at `TokenMinter`.

Eliminated risk class: stale-approval pivots. `approve` + `transferFrom` + consumer compromise = drain at-will.

Push pitfalls and mappings:
- **ERC-777 / ERC-1363 `safeTransfer` reentrancy**: mid-transfer callbacks. Multiple Code4rena findings (Concur 2022-02, Caviar 2022-12). Mitigation: state updates BEFORE transfer; `nonReentrant` on `pullCoverage`.
- **Fee-on-transfer / rebasing**: `safeTransfer(amount)` debits gross, recipient receives net. Spec is silent. Recommend: ACL-curated asset list (governance-curated, what most Aave components do).
- **Recipient upgradability**: `SLIPPAGE_RECIPIENT` is immutable in spec — no risk. Document in NatSpec that this immutability is load-bearing.

## 3. Override / emergency mode design

Spec design (manual flip, no TTL, separate role from consumer) is the right shape. Concrete patterns:

- **Two-key separation enforced at the role layer**, not just the function. Aave V3 ACL Manager: `EMERGENCY_ADMIN` ≠ `POOL_ADMIN`.
- **Manual revert > TTL**. TTL flags are audit-finding magnets; operators forget. MakerDAO `DssEmergencySpells` use the same model — spell executes, follow-up spell unwinds.
- **Emit on flip and on every override-mode pull**. Spec already does (`OverrideModeSet`, `CoveragePulled` with override flag). Off-chain monitor's hook.
- **Bound the override**: bypasses caps but NOT `OnlyRecipient` and NOT asset-balance check. Test must assert.
- **Don't pause `topUp` and `sweep` under override**: treasury must refill or drain regardless. Spec gets this implicitly (override checked only inside `pullCoverage`); document.

Audit references: ChainSecurity CCTP V2 audit; ChainSecurity MakerDAO DssEmergencySpells audit.

## 4. Directional access control (raise vs lower)

OZ AccessManager constraint: a target function selector maps to exactly one role.

Three patterns, ranked:

1. **Two functions, one selector each — recommended.** `raisePullCapPerTx` / `lowerPullCapPerTx`. Directionality enforced inside (`require(newCap > current)`). Each selector its own role+delay. Aave PoolConfigurator pattern.
2. **One function, internal `msg.sender` dispatch.** Loses per-selector delay machinery. Avoid.
3. **Wrapper steward pattern** (Aave Risk Steward). Heavier; warranted only with frequent ops-level lowers.

For VA-96: pattern 1.

## 5. Adversarial unit-test patterns

**Naming**: Foundry/Forge community convention is `test_<Action>_revertWhen_<Condition>` for negative paths, but **the repo uses `test_<Action>_reverts_<Condition>`** — match the repo (see `repo-analysis.md` §5).

**Attack-path tagging**: tag each test with the Path letter from threat model in docstring (`/// @dev Path C: manipulated params`). Auditors love it.

**Fuzz invariants worth writing** (cheap, kill bug classes — even though out of scope per Decision #7):
- `invariant_vaultBalanceMonotonicExceptPullAndSweep` — `balanceOf(vault)` only decreases via `pullCoverage` (from `SLIPPAGE_RECIPIENT`) or `sweep` (from admin). Catches Path A/D regressions.
- `invariant_consumedNeverExceedsCap` — `consumed[asset] <= cap[asset]` when not in override mode.
- `invariant_overrideModeImpliesGuardianCalled` — ghost variable updated only in `setOverrideMode`.
- `invariant_noApproveCalled` — instrumented mock token whose `approve` reverts; vault never calls.
- `invariant_recipientNeverChanges` — `SLIPPAGE_RECIPIENT == ghostRecipient` (trivially holds; documents intent).

References: Trail of Bits invariant blog posts; Recon book (`book.getrecon.xyz`).

## 6. Common pitfalls — concrete checklist

- **ERC-777/1363 reentrancy** via `safeTransfer` → `nonReentrant` on `pullCoverage`; state updates before transfer.
- **FoT / rebasing**: ACL-curated asset list; reject at registry.
- **First-block default state**: `windowStart == 0` rolls over correctly on first call.
- **`block.timestamp`**: no concern at 24h windows; document for L2 deployers.
- **Asset zero / amount zero**: revert; cleaner invariants.
- **`sweep` and `topUp` with caps**: neither consumes window. `sweep` admin-only, bypasses recipient check intentionally; document.
- **`SLIPPAGE_RECIPIENT == 0` in constructor**: revert (already in acceptance criteria).
- **`uint128` packing**: USDC/USDT/GHO fit comfortably. If `uint256` for headroom, accept the second slot.
- **Storage namespace**: ERC-7201 per repo convention (`aave.storage.SlippageCoverageVault`).
- **Override flip mid-tx**: not possible (atomic), but unit test that flipping override between two pulls applies cap to the second.

## Sources

- Chainlink CCIP RateLimiter: https://github.com/code-423n4/2024-11-chainlink/blob/main/contracts/src/ccip/libraries/RateLimiter.sol
- Chainlink rate-limit docs: https://docs.chain.link/ccip/concepts/rate-limit-management/how-rate-limits-work
- Llama Risk Aave GHO CCIP explainer: https://research.llamarisk.com/research/explainer-series-ccip
- Optimism Standard Bridge: https://docs.optimism.io/app-developers/bridging/standard-bridge
- Circle CCTP TokenMessenger: https://github.com/circlefin/evm-cctp-contracts/blob/master/src/TokenMessenger.sol
- ChainSecurity CCTP V2 audit (PDF)
- OpenZeppelin AccessManager: https://docs.openzeppelin.com/contracts/5.x/access-control
- OZ forum: multiple roles per function: https://forum.openzeppelin.com/t/accessmanager-multiple-roles-for-the-same-function/40385
- Aave V3 ACL Manager: https://aave.com/docs/aave-v3/smart-contracts/acl-manager
- Aave V3 PoolConfigurator: https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/protocol/pool/PoolConfigurator.sol
- Aave Risk Steward: https://governance.aave.com/t/risk-stewards-cap-increases-on-aave-v3-2026-05-05/24853
- MakerDAO DssEmergencySpells: https://github.com/sky-ecosystem/dss-emergency-spells
- Trail of Bits invariant blog: https://blog.trailofbits.com/2023/10/05/introducing-invariant-development-as-a-service/
- Recon invariant book: https://book.getrecon.xyz/writing_invariant_tests/learn_invariant_testing.html
- Code4rena ERC-777 reentrancy (Concur): https://github.com/code-423n4/2022-02-concur-findings/issues/260
- Code4rena ERC-777 reentrancy (Caviar): https://github.com/code-423n4/2022-12-caviar-findings/issues/343
- Code4rena Connext FoT: https://github.com/code-423n4/2021-07-connext-findings/issues/11
