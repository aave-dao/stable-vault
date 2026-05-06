# Repo Analysis — Remove Default Strategy (VA-157)

## 1. Reference inventory (delete/refactor/keep) by file

### `src/core/Allocator.sol`
| Line | Kind | Action |
|---|---|---|
| 35 (natspec) | "1 default strategy per asset" assumption doc | delete bullet |
| 66 | `mapping(address asset => address strategy) defaultStrategyByAsset` in `AllocatorStorage` | delete |
| 162-164 | `getDefaultStrategy(address)` view | delete |
| 189-201 | `deposit(...) returns (uint256)` external (default-routing) | replace with `pullIdle` |
| 204-218 | `depositAllowIdle(...)` external (default-routing + try/catch) | fold into `pullIdle` (zero-amount no-op) |
| 230-239 | withdraw default-first try/catch block | delete |
| 244-251 | post-default loop `if (strategy != defaultStrategy)` | drop the if-condition |
| 322-324 | `setDefaultStrategy(address,address) restricted` external | delete |
| 361-363 | `distrustStrategy` auto-clear default branch | delete |
| 596 | `_removeStrategy` `DefaultStrategy(strategy)` revert | delete |
| 611-621 | `_setDefaultStrategy` internal | delete |

### `src/interfaces/IAllocator.sol`
| Line | Kind | Action |
|---|---|---|
| 19 | `event DefaultStrategySet` | delete |
| 38 | `error DefaultStrategy(address)` | delete |
| 162-165 | `getDefaultStrategy` declaration | delete |
| 183-187 | `deposit` declaration | delete |
| 189-195 | `depositAllowIdle` declaration | delete |
| 209-211 | natspec on `withdraw` mentioning default-first | edit to "iterates strategies in insertion order" |
| 225-229 | `setDefaultStrategy` declaration | delete |
| 245-247 | natspec on `distrustStrategy` mentioning auto-unset of default | drop the auto-unset clause |

Add: `pullIdle(address asset, uint256 amount) external` declaration.

### `script/base/RolesConfig.sol`
| Line | Action |
|---|---|
| 435-444 | Delete `getRole__setDefaultStrategy()` helper |
| 658 | Delete array entry; renumber following entries; reduce `new Role[](N)` literal by 1 |

### `script/base/AccessManagerBaseSetup.sol`
| Line | Site | Action |
|---|---|---|
| 269 | `_setupProfile__Rebalancer` (length 6) | drop entry, renumber, length → 5 |
| 299 | `_setupProfile__Disabler` (length 14) | drop entry, renumber, length → 13 |
| 343 | `_setupTarget__Allocator` (length 9) | drop entry, renumber, length → 8 |

### `script/base/AccountingChainDeployment.sol`
- Lines 219, 224, 229: three `allocator.setDefaultStrategy(...)` calls in `_setupAllocator` — delete.

### `script/base/EarningChainDeployment.sol`
- Lines 174, 179: two `allocator.setDefaultStrategy(...)` calls in `_setupAllocator` — delete.

### `test/BaseTest.t.sol`
- Lines 821, 822, 827, 828: four `setDefaultStrategy` setup calls (GHO/USDC × Acct/Earning) — delete.
- Lines 923, 1005: OPERATOR_ROLE selector arrays include `IAllocator.setDefaultStrategy.selector` — drop entry, length → 1 (only `rebalance`).

### `test/mocks/MockAllocator.sol`
- Line 66: `getDefaultStrategy` stub — delete.
- Lines 71-82: `deposit` stub — replace with `pullIdle` stub.
- Line 83: `depositAllowIdle` stub — delete.
- Line 99: `setDefaultStrategy` stub — delete.
- `mockAmountOfSlippage` machinery: drop (no longer reachable through `pullIdle`).

### `test/unit/access/AccessManagerSetupBaseTest.sol`
- Line 199: `expected[1] = getRole__setDefaultStrategy()` in `test_rebalancerProfile_hasTheExpectedRoles` — drop, length → 5, renumber.
- Line 224: `expected[11] = getRole__setDefaultStrategy()` in `test_disablerProfile_hasTheExpectedRoles` — drop, length → 13, renumber.
- Line 408: `_assertTargetFunctionRole(... setDefaultStrategy ...)` in `test_targetSetup_allocator` — drop.
- Line 532: `_assertCanCall(disabler, ..., IAllocator.setDefaultStrategy.selector, true, 0)` — drop.

### `test/unit/access/fork/AccessManager{Earning,Accounting}ChainSetup.Fork.t.sol`
- Earning: lines 38, 39; Accounting: lines 43, 44.
- `vaults[i] = allocator.getDefaultStrategy(asset)` lookups — replace with `allocator.getStrategiesForAsset(asset)[0]` or pin deployed addresses.

### `test/e2e/*.t.sol`
- All e2e tests use `allocator.getDefaultStrategy(asset)` to resolve a strategy address before asserting balances landed there. After the change, deposits stay idle on the Allocator until rebalance.
- Line lists: `EndToEnd.t.sol` 104, 138, 202, 277, 348; `EarningChainWithdrawalTokenFeeE2E.t.sol` 95, 125; `OracleFeedE2E.t.sol` 795, 838; `EarningChainDistrustedAssetE2E.t.sol` 101; `AccountingChainDistrustedAssetE2E.t.sol` 83, 166, 173, 239, 299, 306; `EarningChainWithdrawalE2E.t.sol` 88, 118.
- Pattern: each must (1) drop the `getDefaultStrategy` lookup, (2) assert idle balance lands on Allocator, (3) insert an explicit `RebalanceParams` allocation step before any post-rebalance balance assertions on a strategy. Recommendation: extract a helper `_routeIdleToStrategy(allocator, asset, strategy)` in `BaseTest.t.sol` to keep e2e diffs small.

### `test/unit/periphery/OwnedMulticall.t.sol`
- Lines 127-129: `setDefaultStrategy` setup calls — delete.
- Lines 550, 560: `_buildEntireFlowRebalanceParams` uses `getDefaultStrategy` — replace with explicit handle (`_defaultUsdtStrategy`, `_defaultGhoStrategy` — already held by the test).
- Tests at lines 279, 346, 437, 464, 487 already seed strategies via direct `IERC4626.deposit(amount, address(_allocator))` so they don't need fund-routing changes; just stop reading `getDefaultStrategy`.

### `test/unit/core/Allocator.t.sol`
~50 references; full grouping in §6 below.

### `test/unit/core/accounting/FundsHandler.t.sol`
- `test_processDeposit_pushesFundsToAllocatorWithSlippage` at line 159 — drop or rewrite (slippage path no longer reachable).
- Lines 155, 172, 181, 199: return-value assertions — `netDepositAmount == amount` always. Most pass unchanged.

## 2. Caller chain analysis

### `Allocator.deposit(address,uint256) returns (uint256)`
- `FundsHandler.processDeposit` (`src/core/accounting/FundsHandler.sol:122`): returns the value through to `StableVault.deposit` (line 234). Used at line 247 of `StableVault.deposit` for `originalDepositRay` accounting (line 247-249). User share count uses full `amount`, not net (line 239).
- After change: `pullIdle` returns nothing. `processDeposit` returns input `amount` directly. ABI-stable on `processDeposit returns (uint256)`. `StableVault.deposit` unchanged.

### `Allocator.depositAllowIdle(address,uint256)`
Bridge-callback path:
- CCIP → `CcipAdapter.ccipReceive` (`src/bridging/ccip/CcipAdapter.sol:173`) → `_processMessage` (line 190) → `IChainGateway(GATEWAY).receiveMessage(...)` (line 202).
- `BaseChainGateway.receiveMessage` (`src/core/BaseChainGateway.sol:80`) dispatches to `_receiveFunds(asset, amount)` (line 93) when `hasFunds == true`.
- **Earning Chain**: `EarningChainGateway._receiveFunds` (`src/core/earning/EarningChainGateway.sol:155-157`) → `IAllocator(ALLOCATOR).depositAllowIdle(...)`.
- **Accounting Chain**: `AccountingChainGateway._receiveFunds` (`src/core/accounting/AccountingChainGateway.sol:87-89`) → `IFundsHandler(FUNDS_HANDLER).fundsArrivedFromChainCallback(...)` → `FundsHandler.fundsArrivedFromChainCallback` (`src/core/accounting/FundsHandler.sol:171-173`) → `IAllocator.depositAllowIdle(...)`.
- Also via `CcipAdapter.replayFundsReceiving` (`src/bridging/ccip/CcipAdapter.sol:181-184`).

Return values not consumed in either site. Replace both with `pullIdle`. The `BaseChainGateway:81-101` early-out already filters zero-amount, so the no-op semantics are belt-and-suspenders.

## 3. `Allocator.withdraw` flow change

Current (`src/core/Allocator.sol:221-256`):
1. If `idleBalance < amount`, compute `amountRemaining = amount - idleBalance`.
2. Try default strategy first via try/catch (lines 230-239).
3. Loop `assetStrategies` from index 0, skipping default (lines 242-252).
4. Require `amountRemaining == 0`, transfer (lines 253-255).

After change:
- Delete lines 230-239 entirely (single contiguous edit).
- In the post-loop, drop the `if (strategy != defaultStrategy)` guard. Body becomes flat try/catch withdraw across the whole `assetStrategies` set in insertion order.
- Local variable `defaultStrategy` removed.

Test invariant that newly matters: `assetStrategies` insertion order is whatever `addStrategy` was called with. BaseTest setUp sets `[_defaultUsdtStrategy, _extraUsdtStrategy]`. Tests adding more strategies must reason about position when constructing seeded amounts.

## 4. `_removeStrategy` and validation

- `src/core/Allocator.sol:596` — only revert clause referencing the default mapping. Drop unconditionally. Remaining checks (asset registration, strategy trust, zero share balance) still pin behavior.
- Lines 361-363 (`distrustStrategy` auto-clear) — delete.
- Confirmed: the only places mutating `defaultStrategyByAsset` are `setDefaultStrategy` external + `_setDefaultStrategy` internal (called from `setDefaultStrategy` and `distrustStrategy`).

## 5. `AllocatorStorage` storage layout

ERC-7201 namespaced (slot `0x1467d9b012834ae38d27bf9f208a39b5bf5f9a0c5f0adf25ec219f54e4610e00`). Removing `defaultStrategyByAsset` (offset 0 within namespace) shifts:
- `strategyConfigs`: offset 1 → 0
- `assetStrategies`: offset 2 → 1

For an existing on-chain deployment this would corrupt both shifted mappings. **Pre-launch**, no migration needed. Recommendation: delete the field, no padding gap, no `__deprecated` reservation. PR body must call out the breaking storage change for any pre-launch testnet that already has state.

## 6. `Allocator.t.sol` — test inventory

### Drop entirely (`setDefaultStrategy` semantics)
- `test_setDefaultStrategy_reverts_ifUnauthorizedCaller` (2424)
- `test_setDefaultStrategy_reverts_ifStrategyIsNotSupportedForAsset` (2445)
- `test_setDefaultStrategy_reverts_ifStrategyIsAlreadySet` (2457)
- `test_setDefaultStrategy_reverts_ifStrategyHasDepositsDisabled` (2466)
- `test_removeStrategy_reverts_ifDefaultStrategy` (2477)
- `test_setDefaultStrategy_reverts_ifStrategyIsNotTrusted` (3200)
- `test_setDefaultStrategy_reverts_ifClearingDefaultForUnregisteredAsset` (3213)
- `test_disableDepositsToStrategy_withMultiCall` (2643) — uses `setDefaultStrategy.selector` in multicall payload; rewrite or drop.

### Drop or replace assertions (`getDefaultStrategy`)
- `test_getDefaultStrategy_returnsExpectedDefaultVault` (2324) — drop.
- `test_distrustStrategy_unsetsDefaultStrategy` (3128) — drop.
- `test_distrustStrategy_doesNotEmitDefaultStrategySetIfNotDefault` (3157) — drop.
- `test_trustStrategy_doesNotRestoreDefault` (3233) — drop.

### Drop or rewrite (deposit auto-flow)
- `test_deposit_depositsFundsIntoDefaultVault` (411) — rewrite as "deposit lands idle".
- `test_depositAllowIdle_depositsFundsIntoDefaultVault` (427) — fold into `pullIdle` test.
- `test_deposit_withAllowedAssetWithoutStrategy` (441) — keep (already asserts idle).
- `test_deposit_ifDefaultStrategyIsAddressZero_fundsAreIdle` (463) — drop.
- `test_depositAllowIdle_ifDefaultStrategyIsAddressZero_fundsAreIdle` (486) — drop.
- `test_deposit_reverts_ifSharesMintedIsZero` (506) — drop (slippage path gone).
- `test_deposit_returnsDepositAmount_ifNegativeSlippage` (525) — drop.
- `test_deposit_reverts_ifSlippageExceedsThreshold` (549) — drop.
- `test_deposit_succeeds_ifSlippageWithinThreshold` (568) — drop.
- `test_deposit_reverts_ifPreviewRedeemRevertsInStrategy` (589) — drop.
- `test_depositAllowIdle_doesNotRevert_ifSharesMintedIsZero` (693) — drop.
- `test_deposit_reverts_whereVaultRejectsDeposit` (721) — drop.
- `test_depositAllowIdle_doesNotRevert_ifVaultRejectsDeposit` (740) — drop.
- `test_deposit_reverts_ifNonDepositorCalls` (767) → `test_pullIdle_reverts_ifNonDepositorCalls`.
- `test_depositAllowIdle_reverts_ifNonDepositorCalls` (778) — fold into above.
- `test_deposit_reverts_ifAssetRegistryDoesNotAllowDepositIntoAllocator` (789) → `test_pullIdle_reverts_...`.
- `test_depositAllowIdle_reverts_ifAssetRegistryDoesNotAllowDepositIntoAllocator` (801) — fold.
- `test_deposit_reverts_ifAmountIsZero` (813) — drop or fold; `pullIdle(asset, 0)` is no-op per spec.
- `test_depositAllowIdle_doesNotRevert_ifAmountIsZero` (821) → `test_pullIdle_doesNotRevert_ifAmountIsZero`.
- `test_deposit_reentrancyNotAllowedOnRebalance` (3429) — drop (no auto-deposit means no strategy callback can re-enter from `pullIdle`).
- `test_depositAllowIdle_reentrancyNotAllowedOnRebalance` (3448) — drop.

### Rewrite (default-first withdrawal preference)
- `test_withdraw_withdrawsFromDefaultVault` (863) — rename, seed strategy directly, drop `setDefaultStrategy` reliance.
- `test_withdraw_skipsDefaultStrategyWhenUnset` (909) — drop.
- `test_withdraw_redeemsAllSharesFromDefaultStrategyWhenMaxWithdrawReturnsZero` (1338) — rename, no semantic change.
- `test_withdraw_continuesSearchingStrategiesWhenDefaultStrategyHasNoShares` (1363) — rewrite as "iterates remaining strategies when first strategy has no shares".
- `test_withdraw_withdrawsFullAmountFromDefaultStrategyWhenMaxWithdrawGreaterThanOrEqualToAmount` (1392) — rename.
- `test_withdraw_continuesSearchingStrategiesWhenDefaultStrategyMaxWithdrawReturnsZero` (1418) — rewrite, reorder seeding to match insertion-order iteration.
- `test_withdraw_withdrawsPartialFromDefaultStrategyWhenMaxWithdrawLessThanAmountRequested` (1478) — rewrite similarly.
- `test_withdraw_revertsWithInsufficientFundsWhenMaxWithdrawLessThanAmountAndNoOtherStrategies` (1299) — rename.
- `test_withdraw_reverts_givenMaxWithdrawReturnsZero` (831) — drop `setDefaultStrategy` setup, seed `mockStrategy` directly.

### Auto-clear on `removeStrategy` cleanup
- `test_removeStrategy_removesStrategyFromAssetStrategies` (2487) — drop the `setDefaultStrategy` preamble, post-step, and trailing `getDefaultStrategy` assertion.
- `test_removeStrategy_reverts_ifStrategyHasFunds` (2607) — drop the `setDefaultStrategy` swap; seed via direct `IERC4626.deposit(amount, allocator)`.
- `test_removeStrategy_reverts_ifStrategyIsNotTrusted` (3295) — drop the `setDefaultStrategy` line and the "unset default" comment.

### Other
- Setup block at 159-162 (`setDefaultStrategy` for USDT and GHO) — delete unconditionally.
- `_getDepositIdleFundsRebalanceParams` (2843) — replace `getDefaultStrategy` with parameter or `getStrategiesForAsset(asset)[0]`.
- `test_rabalance_allocate_ifAmountSpecified` (1612), `test_rebalance_allocate_reverts_ifAmountGreaterThanBalance` (1671) — replace with `_defaultUsdtStrategy` / `_defaultGhoStrategy` references already held.
- `test_disableDepositsToStrategy_preventsDepositsToStrategy` (2627) — rewrite as "blocks rebalance allocations to disabled strategy".
- `test_enableDepositsToStrategy_enablesDepositsToStrategy` (2700) — same.
- `_depositToReentrantStrategy` (3365-3371) — drop.

## 7. ACL wiring drops summary

`IAllocator.setDefaultStrategy.selector` is referenced exclusively in:
- `RolesConfig.sol:435-444` (helper) + `:658` (array entry).
- `AccessManagerBaseSetup.sol:269` (Rebalancer profile, length 6 → 5).
- `AccessManagerBaseSetup.sol:299` (Disabler profile, length 14 → 13).
- `AccessManagerBaseSetup.sol:343` (Allocator target setup, length 9 → 8).
- `BaseTest.t.sol:923, :1005`, `AccessManagerSetupBaseTest.sol:199, 224, 408, 532`.

No new selector to wire for `pullIdle` — uses `onlyDepositor`, not `restricted`.

## 8. `pullIdle` signature

```solidity
/// @notice Pulls assets from the TransferHelper into the Allocator and emits AssetLeftIdle.
/// @dev Used by the depositor (FundsHandler / EarningChainGateway) for both user-deposit and bridge-callback flows.
/// Zero amount is a no-op for bridge-callback safety.
function pullIdle(address asset, uint256 amount) external onlyDepositor nonReentrant {
    if (amount == 0) {
        return;
    }
    require(IAssetRegistry(ASSET_REGISTRY).isDepositToAllocatorAllowed(asset), Errors.UnsupportedAsset(asset));
    ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
    emit AssetLeftIdle(asset, amount);
}
```

`onlyDepositor` is defined at `Allocator.sol:82-85`, currently used by both `deposit` and `depositAllowIdle`. `DEPOSITOR` immutable resolves to FundsHandler on Accounting Chain and EarningChainGateway on Earning Chain.

## 9. `processDeposit` ABI consumers

- `StableVault.sol:234` — uses return value for `originalDepositRay`. With `netDepositAmount == amount` always, no behavior change.
- `FundsHandler.t.sol`:
  - `test_processDeposit_pushesFundsToAllocator` (144) — keep, passes unchanged.
  - `test_processDeposit_pushesFundsToAllocatorWithSlippage` (159) — drop or rewrite (slippage path gone).
- `StableVault.t.sol:671` — `expectCall` on selector; keep as-is.

`MockFundsHandler.sol:52` — update.

## 10. Files touching the change

- `src/core/Allocator.sol`
- `src/interfaces/IAllocator.sol`
- `src/core/accounting/FundsHandler.sol`
- `src/core/earning/EarningChainGateway.sol`
- `script/base/RolesConfig.sol`
- `script/base/AccessManagerBaseSetup.sol`
- `script/base/AccountingChainDeployment.sol`
- `script/base/EarningChainDeployment.sol`
- `test/BaseTest.t.sol`
- `test/unit/core/Allocator.t.sol`
- `test/unit/core/accounting/FundsHandler.t.sol`
- `test/unit/access/AccessManagerSetupBaseTest.sol`
- `test/unit/access/fork/AccessManagerEarningChainSetup.Fork.t.sol`
- `test/unit/access/fork/AccessManagerAccountingChainSetup.Fork.t.sol`
- `test/unit/periphery/OwnedMulticall.t.sol`
- `test/e2e/EndToEnd.t.sol` + 5 sibling e2e files
- `test/mocks/MockAllocator.sol`
- `test/mocks/MockFundsHandler.sol`

Total: ~18 files.
