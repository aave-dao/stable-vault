# Framework Docs — SlippageCoverageVault

## Versions pinned

- Solidity: `0.8.28` (`foundry.toml`)
- OpenZeppelin Contracts: `v5.4.0`
- OpenZeppelin Contracts Upgradeable: `v5.4.0`
- Import root: `@openzeppelin/contracts-upgradeable/...` (matches `WithdrawalPolicy.sol`).

## 1. AccessManaged / AccessManager v5

**`restricted` modifier**: delegates to `AccessManager.canCall(caller, target, selector)` (`AccessManager.sol:139`). Allows any account holding the role wired to `(target, selector)`. With non-zero per-member execution delay, immediate call reverts; account must `schedule(...)` then `execute(...)` (or call directly with the modifier consuming the schedule).

**Wiring** (off-contract on AccessManager):
- `setTargetFunctionRole(target, selectors[], roleId)` — selector → role.
- `grantRole(roleId, account, executionDelay)` — member with optional delay.
- `setRoleAdmin`, `setRoleGuardian`, `setGrantDelay`, `setTargetAdminDelay` — meta wiring.

**Delay semantics**: execution delay (clock from `schedule` to earliest valid `execute`). Operations expire after `expiration() = 1 weeks`. With delay active, calling the target directly triggers `restricted` to detect/consume the schedule (`AccessManaged._checkCanCall:95-111`).

**Critical-role pattern**:
- Critical setters (`sweep`, raise of `pullCapPerTx`, raise of `windowCap`) → ADMIN role with `executionDelay = HIGH_DELAY`; GUARDIAN role can `cancel`.
- Operational setters (`setOverrideMode`, `topUp`, lower of caps) → no execution delay.
- Directional ACL by **two distinct selectors** with two role IDs. AccessManager keys on `(target, selector)`; directional split must be at API surface.

**Important**: never put `restricted` on `internal`; avoid on `receive()`/`fallback()`.

References:
- `lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol`, `AccessManaged.sol`, `AccessManagedUpgradeable.sol`
- https://docs.openzeppelin.com/contracts/5.x/access-control#access_management
- https://docs.openzeppelin.com/contracts/5.x/api/access#AccessManager

## 2. ERC-7201 namespaced storage

Formula: `bytes32 slot = keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff))`.

Mask `~0xff` zeros low byte → 256-slot aligned root, room for adjacent fields without overlap.

**No on-chain helper**. Compute off-chain and paste as `private constant` with formula in comment. Repo convention exact match: `WithdrawalPolicy.sol:62-78`. Use `cast keccak` / `chisel` / `forge inspect`.

**Storage gaps**: eliminated under ERC-7201. No `__gap[50]`. OZ v5 upgradeable contracts follow this; repo follows this.

Naming: `aave.storage.SlippageCoverageVault` (mirrors `aave.storage.WithdrawalPolicy`).

References:
- EIP-7201: https://eips.ethereum.org/EIPS/eip-7201
- OZ release notes: https://docs.openzeppelin.com/contracts/5.x/upgradeable#namespaced_storage

## 3. SafeERC20 v5.4

- **`safeTransfer`/`safeTransferFrom`**: wrap raw + validate via `_callOptionalReturn`. Reverts `SafeERC20FailedOperation(token)` on revert, no return data with no code, or non-`true` return. USDT supported (no return value).
- **`forceApprove`**: zero-then-set fallback. Vault NEVER calls `approve`/`forceApprove` (push-based outflow only). Single allowance flow on `topUp` caller side via `safeTransferFrom`.
- **Smart-contract recipient**: `safeTransfer` does NOT call back recipient. Reentrancy only via malicious ERC-20 hooks (ERC-777-style). Aave answer: reject at registry. `nonReentrant` is cheap insurance.

Reference: `lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol`

## 4. Foundry test patterns

- **Selector-only revert**: `vm.expectRevert(IFoo.SomeError.selector)` (param-less errors). Repo example: `test/unit/misc/Multicall.t.sol:29`.
- **Parameterized revert**: `vm.expectRevert(abi.encodeWithSelector(IFoo.SomeError.selector, arg1, arg2))` (line 40). Required for `AccessManagedUnauthorized(caller)`.
- **Time travel**: `vm.warp(block.timestamp + 1 days + 1)` for window edge.
- **Role gates**: `vm.prank(caller)` (member of role, NOT AccessManager).
- **Fuzz bounding**: prefer `bound(uint256, lo, hi)` over `vm.assume`. `foundry.toml` runs 10_000.

Reference: https://book.getfoundry.sh/reference/forge-std/cheatcodes

## 5. `@custom:selector` NatSpec

Project-specific (not standard). Solidity `@custom:` allows arbitrary tags. Repo uses `/// @custom:selector 0xXXXXXXXX` consistently — see `src/types/Errors.sol:10` and 19 other entries; `src/libraries/AssetLib.sol:14`; `src/periphery/OwnedMulticall.sol:14`. Compute with `cast sig "ErrorName(types,...)"`.

## 6. Setter / event surface (familiarity, not ERC-4626 inheritance)

- Cap setters mirror Aave V3 `setReserveCaps` shape (one event per setter, indexed asset).
- `topUp(asset, amount)`: emit `ToppedUp(address indexed asset, address indexed from, uint256 amount)`.
- `sweep(asset, amount, to)`: emit `Swept(address indexed asset, address indexed to, uint256 amount)`.
- `CoveragePulled(address indexed asset, uint256 amount, bool overrideMode)`: central audit event, emitted unconditionally.
- One getter per scalar (`getPullCapPerTx(asset)`, `getWindow(asset)` returning struct) — matches `WithdrawalPolicy.getAssetFeeConfig`.

## 7. ReentrancyGuardTransient on `pullCoverage`

`msg.sender == SLIPPAGE_RECIPIENT` gate alone NOT sufficient. Swapper itself is `ReentrancyGuard` but `pullCoverage` is reachable mid-call from inside the Swapper's target loop in legitimate flow; loop touches user-controlled targets.

**Use `ReentrancyGuardTransientUpgradeable`** (repo standard — `Allocator.sol:9-10`, `StableVault.sol:9-10`, `EarningChainGateway.sol:6-7`). Apply `nonReentrant` to:
- `pullCoverage` (defense in depth — ~100 gas with transient storage)
- `topUp` (calls `safeTransferFrom` from arbitrary caller)
- `sweep` (calls `safeTransfer` to arbitrary `to`)

Setters do not need it.

References:
- `lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardTransientUpgradeable.sol`
- Repo: `Allocator.sol:9-10, 45, 296`

## Files to mirror in repo

- `src/periphery/WithdrawalPolicy.sol` — closest analog (AccessManaged + ERC-7201 + restricted setters + initializer pattern).
- `src/types/Errors.sol` — selector NatSpec convention.
- `src/core/Allocator.sol` — `ReentrancyGuardTransientUpgradeable` usage; modifier order `restricted nonReentrant` (line 296).
- `src/periphery/Swapper.sol` — current Swapper to harden; immutable patterns.
- `test/unit/misc/Multicall.t.sol` — `expectRevert` style examples.

## Deprecation check

OZ Contracts 5.4 is current (May 2026). No announced breaking deprecation for AccessManager, AccessManagedUpgradeable, SafeERC20, ReentrancyGuardTransient.
