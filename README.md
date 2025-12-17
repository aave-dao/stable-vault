# Based Boosted Vaults

Based Boosted Vaults is a semi-fixed rate vault protocol developed by Aave Labs. It allows users to deposit assets into "SubVaults" that offer a specific per-second interest rate, enabling predictable yield generation. Deposited funds are allocated to yield-generating strategies (e.g. Aave). The system tracks each user's original principal independently from accrued interest. In the event the vault cannot meet its total interest obligations, users are prioritized to withdraw at least their original deposit amount.

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

The core component is the `BasedBoostedVault`, which manages user positions, sub-vaults, and interest accrual.
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

- **Accounting Chain**: Hosts the `BasedBoostedVault`, `FundsHandler` and `Allocator` for local yield strategies. It tracks the global state of user deposits and total system liquidity.
- **Earning Chains**: Host `EarningChainGateway` and local `Allocator`s. Funds are bridged here to access yield opportunities not available on the Accounting Chain.

**Manager Roles:**
1. **Bridging Funds**:
   - Managers call `pushFundsToChain` on the `FundsHandler`. This bridges assets via the `AccountingChainGateway` to an Earning Chain.
   - Managers call `pushFundsToAccountingChain` on the `EarningChainGateway` to return funds to the Accounting Chain.
2. **Balance Synchronization**:
   - Managers trigger `sendBalanceUpdateWithFeePayer` on the `EarningChainGateway` to send a balance snapshot back to the Accounting Chain. This ensures the `FundsHandler` on the Accounting Chain is aware of the accrued yield and total assets on remote chains.
3. **Strategy Management**:
   - Managers add, remove, and set default strategies on the `Allocator` to direct funds into the most efficient yield sources.

## User Guide

### Deposits

Users can deposit supported assets into the vault (supported assets are managed on the `AssetRegistry` contract).

1. **Call `deposit`**: The user calls the `deposit(address user, address asset, uint256 amount)` function on the `BasedBoostedVault` contract.
2. **Share Calculation**: The deposited amount is converted into shares of a SubVault based on the current conversion rate.
3. **Position Update**: The user's position is credited with the calculated shares.

### Withdrawals

Withdrawals are a two-step process designed to ensure liquidity management and proper accounting.

1. **Request Withdrawal**:
   - The user calls `requestWithdrawal(address user, uint256 requestedAmountInRay)`.
   - A corresponding amount of the user's shares are burned.
   - **IOU Tokens** are minted to the user, representing their claim on the underlying assets.
   - This action must be performed on the Accounting Chain since the `BasedBoostedVault` is the source of truth for a user's claimable balance.

2. **Bridging IOUs**
    - IOUs can be bridged between chains using the `IouTokenManager.bridgeTokens(...)` function.
    - If bridging from the **Accounting Chain** to an **Earning Chain**, IOUs are locked in the `IouTokenManager` on the source chain, and an equivalent amount is minted on the destination chain.
    - If bridging from an **Earning Chain** to the **Accounting Chain**, IOUs are burned on the source chain, and released from the `IouTokenManager` on the destination chain. IOUs can also be bridged from one Earning Chain to another.
    - This allows users to move their claim on assets to the chain where they wish to withdraw or utilize the IOUs. The reason for this design is to allow users to withdraw even if managers are offline and do not repatriate funds back to the Accounting Chain.

3. **Execute Withdrawal**:
   IOUs can be exchanged for assets on either the Accounting Chain or Earning Chains.

   - **Accounting Chain**:
     - **Contract**: `BasedBoostedVault`
     - **Function**: `executeWithdrawal(...)`
     - **Process**: IOUs are burned via `IouTokenManager`. The `WithdrawalPolicy` is checked for fees. Assets are transferred to the user from the `TransferHelper`.

   - **Earning Chains**:
     - **Contract**: `EarningChainGateway`
     - **Function**: `exchangeIouTokens(...)`
     - **Process**: IOUs are burned locally. The `WithdrawalPolicy` is checked for fees. Assets are withdrawn from the local `Allocator`. A cross-chain message is sent to the Accounting Chain to burn the corresponding locked IOUs. Assets are transferred to the user from the `TransferHelper`.

## Repository Structure

```
based-boosted-vaults/
├── src/                          # Main source code
│   ├── access/                   # Access control contracts
│   ├── bridging/                 # Adapters used by protocol to interface with cross-chain bridges
│   │   ├── across/               # Across adapter logic and interfaces
│   │   └── ccip/                 # Chainlink CCIP adapter logic and interfaces
│   ├── core/                     # Core protocol logic
│   │   ├── accounting/           # Accounting chain logic (Vault, FundsHandler)
│   │   ├── earning/              # Earning chain logic
│   │   └── ious/                 # IOU token management
│   ├── interfaces/               # Protocol interfaces
│   ├── libraries/                # Shared libraries (Math, Assets, etc.)
│   ├── misc/                     # Miscellaneous utilities (contracts inherited by core/periphery contracts)
│   └── periphery/                # Peripheral contracts (WithdrawalPolicy, etc.)
├── test/                         # Test suite
├── script/                       # Deployment scripts
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

Gas snapshots are automatically generated and stored in the `snapshots/` directory. To update snapshots:

```bash
make gas-report
```

Snapshot files generated:

- `BasedBoostedVault.Operations.json`: Gas for user related BasedBoostedVault interactions.

### Format

```bash
forge fmt
```
