// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.10;

import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {ATokenVaultMerklRewardClaimer} from "@aave-vault/ATokenVaultMerklRewardClaimer.sol";

/// @title CompileATokenVaultMerklRewardClaimer
/// @dev This file exists solely to force compilation of ATokenVaultMerklRewardClaimer
/// with its specific size-optimized compiler profile (see compilation_restrictions in foundry.toml).
/// It is not used directly by any contract or script.
/// @dev Avoid importing ATokenVaultMerklRewardClaimer contract in main scripts, as otherwise that will force
/// the entire set of dependencies used by that script to be compiled with the size-optimized profile.
/// We import this contract here so it gets compiled, but then we do not explicitly import it
/// in the deployment scripts. Instead, we deploy manually reading the bytecode from the compiled artifact.
/// @dev `CompileATokenVaultMerklRewardClaimer` contract was created to inherit `ATokenVaultMerklRewardClaimer`
/// instead of only doing the isolated import so we can avoid the `AST source not found` warning.
contract CompileATokenVaultMerklRewardClaimer is ATokenVaultMerklRewardClaimer {
    constructor() ATokenVaultMerklRewardClaimer(address(0), 0, IPoolAddressesProvider(address(0))) {}
}
