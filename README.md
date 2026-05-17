# Stable Vaults

Stable Vaults is a semi-fixed rate vault protocol developed by Aave Labs. It allows users to deposit assets into "SubVaults" that offer a specific per-second interest rate, enabling predictable yield generation. Deposited funds are allocated to yield-generating strategies (e.g. Aave). The system tracks each user's original principal independently from accrued interest. In the event the vault cannot meet its total interest obligations, users are prioritized to withdraw at least their original deposit amount.

The protocol utilizes a modular architecture and cross-chain capabilities, separating accounting logic from earning logic.

## Table of Contents

- [Protocol Overview](#protocol-overview)
- [User Guide](#user-guide)
  - [Deposits](#deposits)
  - [Withdrawals](#withdrawals)
- [Repository Structure](#repository-structure)
- [Dependencies](#dependencies)
- [Development](#development)

## Protocol Overview

The core component is the `StableVault`, which manages user positions, sub-vaults, and interest accrual.
- **SubVaults**: Virtual vaults with a defined `perSecondRate` (interest rate). This rate determines the yield users in a given SubVault earn, effectively translating to an APY number (e.g., a higher rate per second results in a higher APY).
- **User Positions**: Users hold shares in a specific SubVault.
- **IOU Tokens**: Used during the withdrawal process to represent a claim on assets. An IOU token unit represents a unit of the common denomination asset (e.g. USD). IOUs can be exchanged for any asset supported by the system on the chain which the IOUs are being exchanged.

### Yield Generation & Cross-Chain Architecture

Funds deposited into the protocol are managed by `Allocator` contracts (one `Allocator` is deployed to each of the Accounting Chain and Earning Chains), which deploy assets into yield-generating strategies.

**Yield Mechanics:**
- **Allocator**: Holds idle funds and deposits them into whitelisted strategies which act as ERC-4626 compliant adapters to underlying yield-generating protocols.
- **Rebalancing**: Managers can call `rebalance()` on the Allocator to move funds between strategies or swap assets to optimize yield. Swaps are enforced to be 1:1 where a `slippage coverage source` must make up the difference for slippage and/or fees.

**Cross-Chain Flow:**
The protocol operates on a model where the Accounting Chain is the primary command center and Earning Chains act as sources of yield. Contracts on the Earning Chain can only bridge funds back to their canonical Accounting Chain.

- **Accounting Chain**: Hosts the `StableVault`, `FundsHandler` and `Allocator` for local yield strategies. It tracks the global state of user deposits and total system liquidity.
- **Earning Chains**: Host `EarningChainGateway` and local `Allocator`s. Funds are bridged here to access yield opportunities not available on the Accounting Chain.
- **Bridge adapters**: Cross-chain messages and funds move through bridge adapters. The repository currently includes Chainlink CCIP and a.DI adapters.

**Oracle Architecture:**
- **Price oracles (both chains)**:
  - `PriceOracle` is the canonical price entry point for protocol contracts.
  - Asset-specific adapters (e.g. `ChainlinkPriceOracleAdapter`) are registered on `PriceOracle`.
  - `validatePrice` enforces staleness and minimum-valid-price checks for safety-critical flows (e.g. deposits).
  - `getPrice` is used for aggregation and returns `0` for stale prices; prices above `1 RAY` are capped to `1 RAY`.
- **Chain balance oracle (Accounting Chain)**:
  - `FundsHandler` and `AccountingChainGateway` read from `ChainBalanceOracle`.
  - `ChainBalanceOracle` delegates per-chain reads to registered adapters.
  - `ChainlinkChainBalanceOracleAdapter` decodes snapshots published from `EarningChainStateProvider` and marks data stale using heartbeat + buffer.
  - `AccountingChainGateway` validates inbound `RETURN_FUNDS` and `BURN_IOU_TOKEN` messages using source chain block numbers
    (message block number must be `<= sourceChainBlockNumber` from the latest snapshot).
- **Snapshot source**:
  - `EarningChainStateProvider.getState()` encodes the Earning Chain balance snapshot (`balanceRay`, source timestamp, source block number).
  - This snapshot is published by the Chainlink network to a bundle feed consumed by `ChainlinkChainBalanceOracleAdapter`.

**Manager Roles:**
1. **Bridging Funds**:
   - Managers call `pushFundsToChain` on the `FundsHandler`. This bridges assets via the `AccountingChainGateway` to an Earning Chain.
   - Managers call `pushFundsToAccountingChain` on the `EarningChainGateway` to return funds to the Accounting Chain.
2. **Strategy Management**:
   - Managers add, remove, trust, distrust, and order strategies on the `Allocator` to direct funds into the most efficient yield sources.

## User Guide

### Deposits

Users can deposit supported assets into the vault (supported assets are managed on the `AssetRegistry` contract).

1. **Call `deposit`**: The user calls the `deposit(address user, address asset, uint256 amount, bytes calldata policyData)` function on the `StableVault` contract.
2. **Share Calculation**: The deposited amount is converted into shares of a SubVault based on the current conversion rate.
3. **Position Update**: The user's position is credited with the calculated shares.

### Withdrawals

Withdrawals are a two-step process designed to ensure liquidity management and proper accounting.

1. **Request Withdrawal**:
   - The user calls `requestWithdrawal(address user, uint256 requestedAmountInRay, bytes calldata policyData)`.
   - A corresponding amount of the user's shares are burned.
   - **IOU Tokens** are minted to the user, representing their claim on the underlying assets.
   - This action must be performed on the Accounting Chain since the `StableVault` is the source of truth for a user's claimable balance.

2. **Bridging IOUs**
    - IOUs can be bridged between chains using the `IouTokenManager.bridgeTokens(...)` function.
    - If bridging from the **Accounting Chain** to an **Earning Chain**, IOUs are locked in the `IouTokenManager` on the source chain, and an equivalent amount is minted on the destination chain.
    - If bridging from an **Earning Chain** to the **Accounting Chain**, IOUs are burned on the source chain, and released from the `IouTokenManager` on the destination chain. IOUs can also be bridged from one Earning Chain to another.
    - This allows users to move their claim on assets to the chain where they wish to withdraw or utilize the IOUs. The reason for this design is to allow users to withdraw even if managers are offline and do not repatriate funds back to the Accounting Chain.

3. **Execute Withdrawal**:
   IOUs can be exchanged for assets on either the Accounting Chain or Earning Chains.

   - **Accounting Chain**:
     - **Contract**: `StableVault`
     - **Function**: `executeWithdrawal(...)`
     - **Process**: IOUs are burned via `IouTokenManager`. The `WithdrawalExecutionPolicy` enforces the protocol's policies and operational costs associated with the withdrawal. Assets are withdrawn from the local `Allocator` then transferred to the user from the `TransferHelper`.

   - **Earning Chains**:
     - **Contract**: `EarningChainGateway`
     - **Function**: `exchangeIouTokens(...)`
     - **Process**: IOUs are burned locally. The `WithdrawalExecutionPolicy` enforces the protocol's policies and operational costs associated with the withdrawal. Assets are withdrawn from the local `Allocator`. A cross-chain message is sent to the Accounting Chain to burn the corresponding locked IOUs. Assets are transferred to the user from the `TransferHelper`.

## Repository Structure

```
stable-vault/
├── src/                          # Main source code
│   ├── bridging/                 # Adapters used by protocol to interface with cross-chain bridges
│   │   ├── adi/                  # a.DI adapter logic
│   │   └── ccip/                 # Chainlink CCIP adapter logic
│   ├── core/                     # Core protocol logic
│   │   ├── accounting/           # Accounting chain logic (Vault, FundsHandler)
│   │   ├── earning/              # Earning chain logic
│   │   └── ious/                 # IOU token management
│   ├── interfaces/               # Protocol interfaces
│   ├── libraries/                # Shared libraries (Math, Assets, etc.)
│   ├── misc/                     # Miscellaneous utils (contracts inherited by core/periphery contracts)
│   ├── oracles/                  # Price and chain balance oracle contracts and adapters
│   ├── periphery/                # Peripheral contracts (registries, swapper, coverage vault, etc.)
│   ├── policies/                 # Deposit, withdrawal-execution, and funds-bridging policies
│   └── types/                    # Shared constants and errors
├── test/                         # Test suite
├── script/                       # Deployment, upgrade, setup, and interaction scripts
└── lib/                          # Foundry dependencies
```

## Dependencies

### Required

- **[Foundry](https://book.getfoundry.sh/getting-started/installation)** - Development framework
  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup  # Update to latest version
  ```

### Dependency Strategy

Dependencies are managed via git submodules in the `lib` directory.

## Development

### Build

```bash
forge build
```

### Test

```bash
forge test
```

- **Run specific test**: `forge test --match-contract ContractName`
- **Run with verbosity**: `forge test -vvv`

### Gas Snapshots

Gas-cost regression checks live under `test/gas/`. They run on every PR via the `gas-diff` CI job, which compares the new measurements against a baseline uploaded from the latest `master` build and posts a sticky PR comment with the diff. Generated snapshot files (`snapshots/`) are gitignored — the baseline lives only as a CI artifact.

To preview the same numbers locally, use the `gas` profile (which enables `isolate = true` for accurate per-call measurement):

```bash
FOUNDRY_PROFILE=gas forge test
```

Generated files in `snapshots/`:

- `StableVault.Operations.json` — user-facing StableVault interactions
- `BurnIouToken.json` — CCIP `BURN_IOU_TOKEN` message processing (used to size the minimum CCIP `gasLimit`)

### Format

```bash
forge fmt
```
