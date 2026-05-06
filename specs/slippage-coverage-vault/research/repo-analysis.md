# Repo Analysis — SlippageCoverageVault

## 1. AccessManager wiring patterns

Contracts inheriting `AccessManagedUpgradeable` (8): `BaseChainGateway`, `Allocator`, `FundsHandler`, `StableVault`, `IouTokenManager`, `ChainBalanceOracle`, `PriceOracle`, `AssetRegistry`, `WithdrawalPolicy`.

Role taxonomy (`script/base/RolesConfig.sol`):
- Static IDs (`script/base/RolesConfig.sol:31-33`): `ADMIN_ROLE = 0`, `ADMIN_ROLE_GUARDIAN_ROLE = 1`, `OPERATIONAL_ROLE_GUARDIAN_ROLE = 2`.
- Function-based: `_selectorToRoleId(bytes4) = uint64(bytes8(abi.encodePacked(selector, bytes4(0))))` (`RolesConfig.sol:685-687`).
- Delays from JSON: `NO_DELAY=0`, `LOW_DELAY`, `MEDIUM_DELAY`, `HIGH_DELAY`, `CRITICAL_DELAY`.

Setter convention (always `restricted`):
```solidity
function setAssetFeeBps(...) external restricted { ... }   // WithdrawalPolicy.sol:163
function setAssetConfig(...) external override restricted  // AssetRegistry.sol:59
```

**Directional setters: precedent is split-by-function-name, never runtime branching**:
- `enableAllocatorDeposits` HIGH+ADMIN (`RolesConfig.sol:110-119`) vs `disableAllocatorDeposits` NO_DELAY+OPERATIONAL (`RolesConfig.sol:58-67`)
- `trustAsset` HIGH+ADMIN (line 162) vs `distrustAsset` NO_DELAY+OPERATIONAL (line 175)
- `addStrategy` HIGH+ADMIN+critical (line 396) vs `removeStrategy` NO_DELAY+OPERATIONAL (line 409)

For directional cap setters use this convention exactly: `raisePullCapPerTx` / `lowerPullCapPerTx`, each its own selector with its own role wiring. No `if (newCap > oldCap)` branching.

Wiring locations for new functions:
1. `getRole__<fn>()` helper in `RolesConfig.sol`.
2. Append entry to `getAllFunctionBasedRoles()` (line 615-683).
3. New `_setupTarget__SlippageCoverageVault(deployer)` in `script/base/AccessManagerBaseSetup.sol` (style: `_setupTarget__WithdrawalPolicy` line 352-363).
4. Register in `_setup_Targets(deployer)` (line 135-142).
5. Profile grants (e.g. Rebalancer needs `topUp`): add to `_setupProfile__Rebalancer()` (line 260-278).
6. Critical-risk roles (`hasCriticalRisk: true`) excluded from SecondaryAdmin per line 211-246. Mark `sweep`, `raisePullCapPerTx`, `raiseWindowCap`, `setSlippageMaxBps` accordingly.

## 2. ERC-7201 storage namespace pattern

Convention (`src/periphery/AssetRegistry.sol:25-40`, `src/periphery/WithdrawalPolicy.sol:62-78`):
```solidity
/// @custom:storage-location erc7201:aave.storage.AssetRegistry
struct AssetRegistryStorage { ... }

// keccak256(abi.encode(uint256(keccak256("aave.storage.AssetRegistry")) - 1)) & ~bytes32(uint256(0xff))
bytes32 private constant STORAGE_SLOT_ASSET_REGISTRY =
    0xe40dab217194b6f9bf5c5919f11bf88986c74d7e324e41f214286ca4657cc900;

function $storage() private pure returns (AssetRegistryStorage storage _storage) {
    assembly { _storage.slot := STORAGE_SLOT_ASSET_REGISTRY }
}
```

Rules:
- Namespace: `aave.storage.<ContractName>` → `aave.storage.SlippageCoverageVault`.
- Slot constant: `STORAGE_SLOT_<UPPER_SNAKE>`, `private constant`, formula in comment immediately above.
- Accessor: `$storage()`, `private pure`, returns `<ContractName>Storage storage`.
- No `__gap[]` (eliminated under ERC-7201).

## 3. Current Swapper / Allocator / OwnedMulticall behavior

**`Swapper.executeSwap`** (`src/periphery/Swapper.sol:39-74`):
- `Ownable(allocator)` + `nonReentrant`.
- Decodes `(address[] targets, bytes[] callDatas, SlippageParams)`. No length check.
- Loop line 49-52: `targets[i].call(callDatas[i])` — fully arbitrary.
- Line 65: `IERC20(assetOut).safeTransferFrom(slippageParams.slippageCoverageSource, ...)` — replaced by `pullCoverage`.
- `_minToleratedAmountOut` (line 76-82) has no upper bound on `slippageToleranceBps` — the bug.

**`SlippageParams`** declared in-contract (`Swapper.sol:32-35`), not on interface. Move to `ISwapper.sol` per project convention; remove `slippageCoverageSource`.

**`Allocator._swap`** (`src/core/Allocator.sol:404-427`):
- Line 419-421: `amountOut >= amountIn.convertAssetDecimals(...)` — asymmetric 1:1 invariant (only checks `assetOut`).
- Per VA-96: no Allocator changes.

**`OwnedMulticall`** (`src/periphery/OwnedMulticall.sol`): `Ownable`, owner-only `aggregate*`, raw `target.call(callData)`, `renounceOwnership` blocked. Drain paths A/D bypass Allocator entirely.

**Existing wiring**:
- Swapper deployed via CREATE3 with seed `aave.stable-vault.Swapper` (`Create3AddressBook.sol:18`).
- OwnedMulticall deployed twice with seeds `...RebalancerProfile` / `...DisablerProfile`. Rebalancer profile holds `rebalance`, `topUp`, etc. (`AccessManagerBaseSetup.sol:260-278`).
- Existing integration test: `test/unit/periphery/OwnedMulticall.t.sol:279-344` (`test_rebalance_viaOwnedMulticall_swapWithSlippageCoverage`) — manager pre-mints to OwnedMulticall, crafts `aggregate3` first call `IERC20.approve(swapper, slippageAmount)` then `Allocator.rebalance(...)`. This test changes shape post-vault.

## 4. Existing rate-limit / cap patterns

**None.** No per-asset cap, sliding window, throttle, or bucket data structure in `src/`. Closest is `WithdrawalPolicy.FEE_CAP_BPS` (`src/periphery/WithdrawalPolicy.sol:37`) — a single immutable bps cap. Window-bucket logic is greenfield.

## 5. Test conventions

**Naming convention** (use exactly): `test_<fn>_reverts_<cond>` — snake-case `reverts`, **not** `revertWhen_`.
- `test_executeSwap_reverts_ifCallToTargetFailed` (`Swapper.t.sol:389`)
- `test_executeSwap_reverts_ifNotOwner` (`Swapper.t.sol:407`)
- `test_setAssetFeeBps_reverts_ifMsgSenderIsNotAuthorized` (`WithdrawalPolicy.t.sol:69`)
- `test_constructor_reverts_ifZeroAddress` (`OwnedMulticall.t.sol:161`)

**Update interview-notes test list to repo convention.**

Tooling:
- All tests inherit `TestWithHelpers` (`test/helpers/TestWithHelpers.sol`); use `_assumeNotProxyAdmin(fuzzed, target)` (line 27) when calling restricted setters via proxy.
- Mocks: `MockAccessManager.mockAllowCall/mockRejectCall` (used in `OwnedMulticall.t.sol:132-134`, `WithdrawalPolicy.t.sol:78-80`). Use these instead of standing up a real AccessManager.
- Token mocks: `MockNonStandardErc20`, `MockErc20`. Reuse `MockSwapper` where you need the Allocator path.
- `vm.expectRevert(abi.encodeWithSelector(...))` consistently — use bare `vm.expectRevert()` only when multiple revert reasons are possible.
- Fuzz: `_boundAssetAmount` / `_boundAssetAmountAllowingZero` for token amounts; `vm.assume(slippageToleranceBps <= 10_000)` (`Swapper.t.sol:100`).
- Adversarial style: `address attacker = makeAddr("attacker")`. Document attack-path in body comment (`// Path C: ...`), not in name.

## 6. Errors / Constants / interface conventions

**Errors location**:
- Shared across contracts → `src/types/Errors.sol` library (`Errors.sol:8-80`).
- Specific to one contract → on the **interface** with `@custom:selector` natspec.

**`@custom:selector` format** (used everywhere):
```solidity
/// @notice <description>.
/// @custom:selector 0x<8-hex>
error <ErrorName>(<args>);
```
Compute manually with `cast sig "ErrorName(args,...)"`.

**Interface file required**: every restricted-surface contract has `I<Name>.sol` in `src/interfaces/`. Move structs and events used in public API onto the interface (cf. `IAllocator.SwapParams`, `IWithdrawalPolicy.WithdrawalRequest`). Reuse `Errors.ZeroAddress`, `Errors.ZeroAmount`, `Errors.InvalidAmount`, `Errors.NotAuthorized` rather than redeclaring.

`OnlyXxx` precedent: `OnlyGateway`, `OnlySelf`, `OnlyStableVault`, `OnlyFundsHandler`, `OnlyDestinationChainAdapter`, `OnlyBridgeRouter`, `OnlyUser`, `OnlyAccountingChain`, `OnlyIouTokenManager`. Use `OnlyRecipient` (or `OnlySwapper`) on `ISlippageCoverageVault`.

## 7. Deployment / wiring shape

Closest model: `EarningChainStateProvider` (most recently added periphery contract).

Steps:
1. `src/interfaces/ISlippageCoverageVault.sol` — events, errors, structs.
2. `src/periphery/SlippageCoverageVault.sol` — implementation.
3. `script/base/Create3AddressBook.sol`:
   - Add `SLIPPAGE_COVERAGE_VAULT_SALT_SEED = "aave.stable-vault.SlippageCoverageVault"` (line 8-22).
   - Add `getSlippageCoverageVaultAddress(address deployer)` helper (line 24-82).
4. `script/base/EarningChainDeployment.sol` and `AccountingChainDeployment.sol`:
   - `_deploySlippageCoverageVault()` returning the proxy address. Use upgradeable pattern: deploy implementation, then `_deployTransparentProxy_create3` with seed + initCalldata. Style: `_deployEarningChainStateProvider` at `EarningChainDeployment.sol:393-409`.
   - Register in `_deployContracts()` (line 106-119).
   - Swapper redeploy: change constructor to `Swapper(allocator, slippageVault)`. Both addresses immutable. CREATE3 prediction in `Create3AddressBook` breaks the circular dependency at deploy time.
5. `script/base/AccessManagerBaseSetup.sol`:
   - `_setupTarget__SlippageCoverageVault(deployer)` mirroring `_setupTarget__WithdrawalPolicy` (line 352-363).
   - Register in `_setup_Targets` (line 135-142).
   - Rebalancer profile probably needs `topUp` (mirrors today's Allocator `topUp` — OPERATIONAL+NO_DELAY).
6. `script/base/RolesConfig.sol`:
   - One `getRole__<setterName>()` per restricted entrypoint (raise & lower split).
   - Append to `getAllFunctionBasedRoles()` (bump array length at line 616).

**Swapper redeploy invalidates existing AccessManager grants** pointed at the old Swapper. Deployment ticket re-wires; PR body must list the wiring delta.

PR body conventions (per VA-96 acceptance gate): list (a) new salt seeds, (b) new role entries with delay+guardian columns, (c) target setup additions, (d) profile-grant changes, (e) breaking changes from Swapper redeploy.

## File pointer summary

- `src/periphery/Swapper.sol` — current implementation to harden + redeploy.
- `src/periphery/OwnedMulticall.sol` — coverage source today (paths A/D).
- `src/core/Allocator.sol:404-427` — `_swap` 1:1 invariant; do not touch.
- `src/periphery/WithdrawalPolicy.sol` — closest analog for AccessManaged + ERC-7201 + restricted setters.
- `src/types/Errors.sol` — shared error library + selector NatSpec convention.
- `script/base/RolesConfig.sol`, `AccessManagerBaseSetup.sol`, `Create3AddressBook.sol`, `EarningChainDeployment.sol` — deployment wiring sites.
- `test/unit/periphery/OwnedMulticall.t.sol:279-344` — integration coverage test today; rewrite to use vault.
- `test/helpers/TestWithHelpers.sol`, `test/mocks/MockAccessManager.sol` — reuse for tests.
